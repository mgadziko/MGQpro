import AudioToolbox
import Foundation

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != Self.unknown }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }

    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        let count = Int(size) / MemoryLayout<T>.size
        var items = [T](repeating: defaultValue, count: count)
        status = items.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return items
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var cfString: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &cfString)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return cfString as String
    }

    func waitUntilReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? read(kAudioObjectPropertyName, defaultValue: "" as CFString)) != nil {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return false
    }

    static func readProcessList() throws -> [AudioObjectID] {
        try system.readArray(
            kAudioHardwarePropertyProcessObjectList,
            defaultValue: AudioObjectID.unknown
        )
    }

    func readProcessPID() throws -> pid_t {
        try read(kAudioProcessPropertyPID, defaultValue: pid_t(0))
    }

    func readProcessIsRunning() -> Bool {
        (try? read(kAudioProcessPropertyIsRunning, defaultValue: UInt32(0))) != 0
    }

    func readProcessBundleID() -> String? {
        try? readString(kAudioProcessPropertyBundleID)
    }
}

extension AudioDeviceID {
    private static let outputStreamDirection: UInt32 = 0

    static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID.unknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(AudioObjectID.system, &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID.isValid ? deviceID : nil
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readNominalSampleRate() throws -> Double {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(48_000))
    }

    func preferredStereoChannelIndices() -> (left: Int, right: Int) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * channels.count)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &channels)
        guard status == noErr, channels.count >= 2 else { return (0, 1) }

        return (Swift.max(0, Int(channels[0]) - 1), Swift.max(0, Int(channels[1]) - 1))
    }

    func firstOutputStreamIndex() throws -> UInt {
        let globalStreams = try readStreams(scope: kAudioObjectPropertyScopeGlobal)
        for (index, streamID) in globalStreams.enumerated() {
            let direction: UInt32 = try streamID.read(kAudioStreamPropertyDirection, defaultValue: 0)
            if direction == Self.outputStreamDirection {
                return UInt(index)
            }
        }

        let outputStreams = try readStreams(scope: kAudioObjectPropertyScopeOutput)
        if !outputStreams.isEmpty {
            return 0
        }

        throw NSError(domain: "MGQ.AudioDeviceID.Streams", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "No output stream found"
        ])
    }

    private func readStreams(scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: .unknown, count: count)
        status = streams.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return streams
    }
}
