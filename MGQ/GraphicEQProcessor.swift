import Accelerate
import Foundation

final class GraphicEQProcessor: @unchecked Sendable {
    private let maxSections: Int
    private var sampleRate: Double
    private var leftSetup: vDSP_biquad_Setup?
    private var rightSetup: vDSP_biquad_Setup?
    private let delayBufferL: UnsafeMutablePointer<Float>
    private let delayBufferR: UnsafeMutablePointer<Float>
    private let delayBufferSize: Int

    private nonisolated(unsafe) var enabled = true

    init(sampleRate: Double, bandCount: Int) {
        self.sampleRate = sampleRate
        self.maxSections = bandCount
        self.delayBufferSize = (2 * bandCount) + 2
        self.delayBufferL = .allocate(capacity: delayBufferSize)
        self.delayBufferR = .allocate(capacity: delayBufferSize)
        delayBufferL.initialize(repeating: 0, count: delayBufferSize)
        delayBufferR.initialize(repeating: 0, count: delayBufferSize)
        let flatGains = Array(repeating: Float(0), count: bandCount)
        update(leftGains: flatGains, rightGains: flatGains, frequencies: EqualizerBand.graphic31Frequencies, isEnabled: true)
    }

    deinit {
        if let leftSetup {
            vDSP_biquad_DestroySetup(leftSetup)
        }
        if let rightSetup {
            vDSP_biquad_DestroySetup(rightSetup)
        }
        delayBufferL.deallocate()
        delayBufferR.deallocate()
    }

    func update(leftGains: [Float], rightGains: [Float], frequencies: [Double], isEnabled: Bool) {
        enabled = isEnabled
        let leftCoefficients = Self.coefficientsForGraphicBands(
            gains: leftGains,
            frequencies: frequencies,
            sampleRate: sampleRate
        )
        let rightCoefficients = Self.coefficientsForGraphicBands(
            gains: rightGains,
            frequencies: frequencies,
            sampleRate: sampleRate
        )
        let newLeftSetup = leftCoefficients.withUnsafeBufferPointer { pointer in
            vDSP_biquad_CreateSetup(pointer.baseAddress!, vDSP_Length(maxSections))
        }
        let newRightSetup = rightCoefficients.withUnsafeBufferPointer { pointer in
            vDSP_biquad_CreateSetup(pointer.baseAddress!, vDSP_Length(maxSections))
        }

        let oldLeftSetup = leftSetup
        let oldRightSetup = rightSetup
        leftSetup = newLeftSetup
        rightSetup = newRightSetup
        if oldLeftSetup != nil || oldRightSetup != nil {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if let oldLeftSetup {
                    vDSP_biquad_DestroySetup(oldLeftSetup)
                }
                if let oldRightSetup {
                    vDSP_biquad_DestroySetup(oldRightSetup)
                }
            }
        }
    }

    func updateSampleRate(_ newSampleRate: Double, leftGains: [Float], rightGains: [Float], frequencies: [Double], isEnabled: Bool) {
        sampleRate = newSampleRate
        memset(delayBufferL, 0, delayBufferSize * MemoryLayout<Float>.size)
        memset(delayBufferR, 0, delayBufferSize * MemoryLayout<Float>.size)
        update(leftGains: leftGains, rightGains: rightGains, frequencies: frequencies, isEnabled: isEnabled)
    }

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard enabled, let leftSetup, let rightSetup else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
            return
        }

        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }

        vDSP_biquad(leftSetup, delayBufferL, output, 2, output, 2, vDSP_Length(frameCount))
        vDSP_biquad(rightSetup, delayBufferR, output.advanced(by: 1), 2, output.advanced(by: 1), 2, vDSP_Length(frameCount))

        if output[0].isNaN || output[1].isNaN {
            memset(delayBufferL, 0, delayBufferSize * MemoryLayout<Float>.size)
            memset(delayBufferR, 0, delayBufferSize * MemoryLayout<Float>.size)
            memset(output, 0, frameCount * 2 * MemoryLayout<Float>.size)
        }
    }

    private static func coefficientsForGraphicBands(gains: [Float], frequencies: [Double], sampleRate: Double) -> [Double] {
        var allCoefficients: [Double] = []
        allCoefficients.reserveCapacity(frequencies.count * 5)

        for (index, frequency) in frequencies.enumerated() {
            guard frequency > 0, frequency < sampleRate / 2 else {
                allCoefficients.append(contentsOf: [1, 0, 0, 0, 0])
                continue
            }

            allCoefficients.append(contentsOf: peakingEQCoefficients(
                frequency: frequency,
                gainDB: gains.indices.contains(index) ? gains[index] : 0,
                q: 1.4,
                sampleRate: sampleRate
            ))
        }

        return allCoefficients
    }

    private static func peakingEQCoefficients(frequency: Double, gainDB: Float, q: Double, sampleRate: Double) -> [Double] {
        let a = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha / a

        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}
