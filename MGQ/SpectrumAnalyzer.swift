import Foundation

final class SpectrumAnalyzer: @unchecked Sendable {
    private let frequencies: [Double]
    private var sampleRate: Double
    private var coefficients: [Float]
    private var levels: [Float]
    private var holdLevels: [Float]

    init(sampleRate: Double, frequencies: [Double]) {
        self.sampleRate = sampleRate
        self.frequencies = frequencies
        self.coefficients = Array(repeating: 0, count: frequencies.count)
        self.levels = Array(repeating: -72, count: frequencies.count)
        self.holdLevels = Array(repeating: -72, count: frequencies.count)
        updateSampleRate(sampleRate)
    }

    func updateSampleRate(_ newSampleRate: Double) {
        sampleRate = newSampleRate
        for (index, frequency) in frequencies.enumerated() {
            guard frequency > 0, frequency < newSampleRate / 2 else {
                coefficients[index] = 0
                continue
            }

            let normalized = 2.0 * Double.pi * frequency / newSampleRate
            coefficients[index] = Float(2.0 * cos(normalized))
        }
    }

    func process(input: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        guard frameCount > 0, channels > 0 else { return }

        for band in frequencies.indices {
            var q0: Float = 0
            var q1: Float = 0
            var q2: Float = 0
            let coefficient = coefficients[band]

            for frame in 0..<frameCount {
                let base = frame * channels
                let sample: Float
                if channels > 1 {
                    sample = (input[base] + input[base + 1]) * 0.5
                } else {
                    sample = input[base]
                }

                q0 = coefficient * q1 - q2 + sample
                q2 = q1
                q1 = q0
            }

            let power = max(q1 * q1 + q2 * q2 - coefficient * q1 * q2, 0)
            let magnitude = sqrt(power) / Float(frameCount)
            let db = max(-72, min(12, 20 * log10(max(magnitude, 0.000_001))))
            let previous = levels[band]
            let smoothing: Float = db > previous ? 0.42 : 0.12
            levels[band] = previous + (db - previous) * smoothing

            let hold = holdLevels[band]
            holdLevels[band] = max(levels[band], hold - 0.8)
        }
    }

    func snapshot() -> [Float] {
        levels
    }
}
