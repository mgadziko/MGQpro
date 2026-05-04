import Foundation
import CoreAudio
import AudioToolbox

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var selectedOutputDeviceID: AudioDeviceID?

    func refreshOutputDevices() {
        var devices: [AudioDeviceID] = []
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            outputDevices = []
            return
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        devices = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else {
            outputDevices = []
            return
        }

        outputDevices = devices.compactMap { deviceID in
            guard hasOutputStreams(deviceID) else { return nil }
            return AudioOutputDevice(
                id: deviceID,
                uid: (try? deviceID.readDeviceUID()) ?? "device-\(deviceID)",
                name: stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "Output \(deviceID)",
                manufacturer: stringProperty(deviceID, selector: kAudioObjectPropertyManufacturer) ?? "Unknown"
            )
        }

        if selectedOutputDeviceID == nil {
            selectedOutputDeviceID = defaultOutputDevice()
        }
    }

    private func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return false
        }
        return dataSize > 0
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr else {
            return nil
        }
        return deviceID
    }

    private func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        return status == noErr ? value as String : nil
    }
}
