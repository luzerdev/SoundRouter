import CoreAudio
import Foundation
import os

/// Peak levels written by the IO thread and read by the UI. Torn reads of a Float are harmless here.
final class LevelMeter {
    var left: Float = 0
    var right: Float = 0
}

/// One stage of effects (an app's or an output's settings), processed on the IO thread.
/// Parameters are handed over without allocating or freeing on the IO thread: the previous
/// parameters are parked in `trash` and released by the main thread on its next update.
final class EffectProcessor {
    struct Parameters {
        var gain: Float = 1
        var muted = false
        var balance: Float = 0
        var eq: [BiquadCoefficients]?
        var boost: Float = 0
        var units: [AURenderer] = []
    }

    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()
    private var pending: Parameters?
    private var trash: Parameters?

    private var parameters = Parameters()
    private var eqLeft = [BiquadState](repeating: BiquadState(), count: GraphicEQ.frequencies.count)
    private var eqRight = [BiquadState](repeating: BiquadState(), count: GraphicEQ.frequencies.count)
    private var compressor: Compressor
    private var smoothedGain: Float = 1
    private let smoothing: Float

    init(sampleRate: Double) {
        compressor = Compressor(sampleRate: sampleRate)
        smoothing = Float(1 - exp(-1 / (0.010 * sampleRate)))
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Main thread.
    func update(_ new: Parameters) {
        os_unfair_lock_lock(lock)
        let oldPending = pending
        let oldTrash = trash
        pending = new
        trash = nil
        os_unfair_lock_unlock(lock)
        _ = (oldPending, oldTrash) // released here, on the caller's thread
    }

    /// IO thread. In place.
    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int, forceMute: Bool) {
        if os_unfair_lock_trylock(lock) {
            if pending != nil {
                trash = parameters
                parameters = pending!
                pending = nil
            }
            os_unfair_lock_unlock(lock)
        }

        if let eq = parameters.eq {
            for band in 0..<min(eq.count, eqLeft.count) {
                eqLeft[band].process(l, frames: frames, eq[band])
                eqRight[band].process(r, frames: frames, eq[band])
            }
        }

        if parameters.boost > 0 {
            compressor.process(l, r, frames: frames, amount: parameters.boost)
        }

        for unit in parameters.units {
            unit.process(l, r, frames: frames)
        }

        let target: Float = (parameters.muted || forceMute) ? 0 : parameters.gain
        let balanceLeft = min(1, 1 - parameters.balance)
        let balanceRight = min(1, 1 + parameters.balance)
        var gain = smoothedGain
        for i in 0..<frames {
            gain += (target - gain) * smoothing
            l[i] *= gain * balanceLeft
            r[i] *= gain * balanceRight
        }
        smoothedGain = abs(gain - target) < 1e-5 ? target : gain
    }
}

/// Renders one routed stream: reads two channels from the aggregate's input (tap or input device),
/// runs the effect stages, and writes the result to the aggregate's output device.
final class StreamProcessor {
    static let maxFrames = 8192

    let stages: [EffectProcessor]
    let meter = LevelMeter()
    var inputOffset = 0
    var mono = false
    var forceMute = false

    private let left = UnsafeMutablePointer<Float>.allocate(capacity: StreamProcessor.maxFrames)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: StreamProcessor.maxFrames)
    private var limiter: Limiter

    init(stageCount: Int, sampleRate: Double) {
        stages = (0..<stageCount).map { _ in EffectProcessor(sampleRate: sampleRate) }
        limiter = Limiter(sampleRate: sampleRate)
        left.initialize(repeating: 0, count: Self.maxFrames)
        right.initialize(repeating: 0, count: Self.maxFrames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard let first = outList.first, first.mNumberChannels > 0 else { return }
        let frames = min(Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels)), Self.maxFrames)

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if !Self.read(inList, channel: inputOffset, into: left, frames: frames) {
            left.update(repeating: 0, count: frames)
        }
        if mono || !Self.read(inList, channel: inputOffset + 1, into: right, frames: frames) {
            right.update(from: left, count: frames)
        }

        for stage in stages {
            stage.process(left, right, frames: frames, forceMute: forceMute)
        }
        limiter.process(left, right, frames: frames)

        var peakLeft: Float = 0, peakRight: Float = 0
        for i in 0..<frames {
            peakLeft = max(peakLeft, abs(left[i]))
            peakRight = max(peakRight, abs(right[i]))
        }
        meter.left = peakLeft
        meter.right = peakRight

        var outputChannels = 0
        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            outputChannels += Int(buffer.mNumberChannels)
        }
        if outputChannels >= 2 {
            Self.write(outList, channel: 0, from: left, frames: frames)
            Self.write(outList, channel: 1, from: right, frames: frames)
        } else {
            for i in 0..<frames { left[i] = (left[i] + right[i]) * 0.5 }
            Self.write(outList, channel: 0, from: left, frames: frames)
        }
    }

    /// Copies logical channel `channel` (counting across all buffers, interleaved or not) into `destination`.
    private static func read(_ list: UnsafeMutableAudioBufferListPointer, channel: Int, into destination: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        var base = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if channel < base + channels, let data = buffer.mData {
                let source = data.assumingMemoryBound(to: Float.self)
                let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
                let count = min(frames, available)
                let index = channel - base
                for i in 0..<count { destination[i] = source[i * channels + index] }
                if count < frames { (destination + count).update(repeating: 0, count: frames - count) }
                return true
            }
            base += channels
        }
        return false
    }

    private static func write(_ list: UnsafeMutableAudioBufferListPointer, channel: Int, from source: UnsafeMutablePointer<Float>, frames: Int) {
        var base = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if channel < base + channels, let data = buffer.mData {
                let destination = data.assumingMemoryBound(to: Float.self)
                let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
                let index = channel - base
                for i in 0..<min(frames, available) { destination[i * channels + index] = source[i] }
                return
            }
            base += channels
        }
    }
}
