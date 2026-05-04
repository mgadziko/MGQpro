import Foundation
import CoreAudio

enum AudioInputMode: String, CaseIterable, Identifiable {
    case systemOutput
    case application

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemOutput:
            return "All System Audio"
        case .application:
            return "Selected App"
        }
    }
}

enum EQChannel: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left:
            return "Left Channel"
        case .right:
            return "Right Channel"
        }
    }
}

struct RunningAudioApp: Identifiable, Hashable {
    let id: String
    let processID: pid_t
    let processObjectIDs: [AudioObjectID]
    let name: String
    let bundleIdentifier: String?
}

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let manufacturer: String
}

struct EqualizerBand: Identifiable, Hashable {
    let id: Int
    let frequency: Double
    var gain: Float
}

extension EqualizerBand {
    static let graphic31Frequencies: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1_000, 1_250, 1_600,
        2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000, 10_000,
        12_500, 16_000, 20_000
    ]

    var displayFrequency: String {
        if frequency >= 1_000 {
            let khz = frequency / 1_000
            return khz == floor(khz) ? "\(Int(khz))k" : String(format: "%.1fk", khz)
        }
        return frequency == floor(frequency) ? "\(Int(frequency))" : String(format: "%.1f", frequency)
    }
}
