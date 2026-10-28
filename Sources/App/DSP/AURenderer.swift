import AudioToolbox
import AVFoundation
import Foundation

/// Hosts an Audio Unit effect inside our IOProc by calling its render block directly.
final class AURenderer {
    let configID: UUID
    let audioUnit: AUAudioUnit
    private let renderBlock: AURenderBlock
    private let pullInput: AURenderPullInputBlock
    private let inputLeft: UnsafeMutablePointer<Float>
    private let inputRight: UnsafeMutablePointer<Float>
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let maxFrames: Int
    private var sampleTime: Float64 = 0

    init(configID: UUID, audioUnit: AUAudioUnit, sampleRate: Double, maxFrames: Int) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CoreAudioError(status: kAudioUnitErr_FormatNotSupported, operation: "Audio Unit format")
        }
        self.configID = configID
        self.audioUnit = audioUnit
        self.maxFrames = maxFrames
        audioUnit.maximumFramesToRender = AUAudioFrameCount(maxFrames)
        if audioUnit.inputBusses.count > 0 {
            try audioUnit.inputBusses[0].setFormat(format)
        }
        try audioUnit.outputBusses[0].setFormat(format)
        try audioUnit.allocateRenderResources()
        renderBlock = audioUnit.renderBlock

        let left = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        left.initialize(repeating: 0, count: maxFrames)
        right.initialize(repeating: 0, count: maxFrames)
        inputLeft = left
        inputRight = right
        outputList = AudioBufferList.allocate(maximumBuffers: 2)

        // Captures raw pointers only, so calling it on the IO thread does no reference counting.
        pullInput = { _, _, frameCount, _, inputData in
            let list = UnsafeMutableAudioBufferListPointer(inputData)
            let bytes = Int(frameCount) * MemoryLayout<Float>.size
            for index in 0..<min(list.count, 2) {
                let source = index == 0 ? left : right
                if let data = list[index].mData {
                    data.copyMemory(from: source, byteCount: bytes)
                } else {
                    list[index].mData = UnsafeMutableRawPointer(source)
                }
                list[index].mDataByteSize = UInt32(bytes)
            }
            return noErr
        }
    }

    deinit {
        audioUnit.deallocateRenderResources()
        inputLeft.deallocate()
        inputRight.deallocate()
        free(outputList.unsafeMutablePointer)
    }

    /// In-place stereo processing. Called on the IO thread.
    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames <= maxFrames else { return }
        let bytes = frames * MemoryLayout<Float>.size
        inputLeft.update(from: left, count: frames)
        inputRight.update(from: right, count: frames)

        outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: UnsafeMutableRawPointer(left))
        outputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: UnsafeMutableRawPointer(right))

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        let status = renderBlock(&flags, &timestamp, AUAudioFrameCount(frames), 0, outputList.unsafeMutablePointer, pullInput)
        sampleTime += Float64(frames)

        if status != noErr {
            left.update(from: inputLeft, count: frames)
            right.update(from: inputRight, count: frames)
            return
        }
        // An AU may hand back its own buffers instead of filling ours.
        copyIfReplaced(index: 0, into: left, frames: frames)
        copyIfReplaced(index: 1, into: right, frames: frames)
    }

    @inline(__always)
    private func copyIfReplaced(index: Int, into destination: UnsafeMutablePointer<Float>, frames: Int) {
        if let data = outputList[index].mData, data != UnsafeMutableRawPointer(destination) {
            destination.update(from: data.assumingMemoryBound(to: Float.self), count: frames)
        }
    }
}
