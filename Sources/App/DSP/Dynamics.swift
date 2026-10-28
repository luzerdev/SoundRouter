import Foundation

/// Stereo-linked compressor with makeup gain ("Magic Boost").
struct Compressor {
    private var envelope: Float = 0
    private var attack: Float = 0
    private var release: Float = 0

    init(sampleRate: Double) {
        attack = Float(exp(-1 / (0.005 * sampleRate)))
        release = Float(exp(-1 / (0.150 * sampleRate)))
    }

    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int, amount: Float) {
        let thresholdDB = -10 - 20 * amount
        let ratio = 2 + 4 * amount
        let makeupDB = 12 * amount
        let slope = 1 - 1 / ratio
        var env = envelope
        for i in 0..<frames {
            let level = max(abs(l[i]), abs(r[i]))
            let coef = level > env ? attack : release
            env = coef * env + (1 - coef) * level
            let envDB = 20 * log10(env + 1e-9)
            let over = envDB - thresholdDB
            let reductionDB = over > 0 ? over * slope : 0
            let gain = powf(10, (makeupDB - reductionDB) / 20)
            l[i] *= gain
            r[i] *= gain
        }
        envelope = env
    }
}

/// Instant-attack peak limiter. Keeps boosted audio (up to 400%) from clipping.
struct Limiter {
    private var envelope: Float = 0
    private var release: Float = 0
    private let ceiling: Float = 0.97

    init(sampleRate: Double) {
        release = Float(exp(-1 / (0.080 * sampleRate)))
    }

    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        var env = envelope
        for i in 0..<frames {
            let peak = max(abs(l[i]), abs(r[i]))
            env = max(peak, env * release)
            if env > ceiling {
                let gain = ceiling / env
                l[i] *= gain
                r[i] *= gain
            }
        }
        envelope = env < 1e-9 ? 0 : env
    }
}
