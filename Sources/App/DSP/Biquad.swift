import Foundation

struct BiquadCoefficients {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    static let identity = BiquadCoefficients()

    private init() {}

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    // RBJ Audio EQ Cookbook designs.

    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        return .init(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a,
                     a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
    }

    static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let c = cos(w0)
        let alpha = sin(w0) / 2 * sqrt(2)
        let k = 2 * sqrt(a) * alpha
        return .init(b0: a * ((a + 1) - (a - 1) * c + k),
                     b1: 2 * a * ((a - 1) - (a + 1) * c),
                     b2: a * ((a + 1) - (a - 1) * c - k),
                     a0: (a + 1) + (a - 1) * c + k,
                     a1: -2 * ((a - 1) + (a + 1) * c),
                     a2: (a + 1) + (a - 1) * c - k)
    }

    static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let c = cos(w0)
        let alpha = sin(w0) / 2 * sqrt(2)
        let k = 2 * sqrt(a) * alpha
        return .init(b0: a * ((a + 1) + (a - 1) * c + k),
                     b1: -2 * a * ((a - 1) + (a + 1) * c),
                     b2: a * ((a + 1) + (a - 1) * c - k),
                     a0: (a + 1) - (a - 1) * c + k,
                     a1: 2 * ((a - 1) - (a + 1) * c),
                     a2: (a + 1) - (a - 1) * c - k)
    }

    private static func clampFrequency(_ f: Double, _ sampleRate: Double) -> Double {
        min(f, sampleRate * 0.45)
    }
}

struct BiquadState {
    var z1: Float = 0
    var z2: Float = 0

    /// Transposed direct form II, in place.
    @inline(__always)
    mutating func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, _ c: BiquadCoefficients) {
        var z1 = self.z1, z2 = self.z2
        for i in 0..<frames {
            let x = buffer[i]
            let y = c.b0 * x + z1
            z1 = c.b1 * x - c.a1 * y + z2
            z2 = c.b2 * x - c.a2 * y
            buffer[i] = y
        }
        // Flush denormals.
        self.z1 = abs(z1) < 1e-20 ? 0 : z1
        self.z2 = abs(z2) < 1e-20 ? 0 : z2
    }
}

/// The 10-band graphic EQ used for app, input and output effects.
enum GraphicEQ {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let range: ClosedRange<Float> = -12...12

    static func coefficients(gains: [Float], sampleRate: Double) -> [BiquadCoefficients] {
        frequencies.enumerated().map { index, frequency in
            let gain = Double(index < gains.count ? gains[index] : 0)
            if index == 0 { return .lowShelf(frequency: frequency * 1.4, gainDB: gain, sampleRate: sampleRate) }
            if index == frequencies.count - 1 { return .highShelf(frequency: frequency * 0.7, gainDB: gain, sampleRate: sampleRate) }
            return .peaking(frequency: frequency, q: 1.41, gainDB: gain, sampleRate: sampleRate)
        }
    }
}
