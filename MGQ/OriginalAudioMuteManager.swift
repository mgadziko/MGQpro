import Foundation
import CoreAudio

@MainActor
final class OriginalAudioMuteManager: ObservableObject {
    @Published var statusMessage = "Original audio unmuted"

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var mutedProcessObjectID = AudioObjectID(kAudioObjectUnknown)
    private var previousAudibleValue: UInt32?

    @discardableResult
    func muteOriginalAudio(for processID: pid_t) -> Bool {
        guard mutedProcessObjectID == kAudioObjectUnknown else { return true }

        do {
            let processObjectID = try coreAudioProcessObjectID(for: processID)
            previousAudibleValue = try processAudibleValue(for: processObjectID)
            try setProcessAudible(false, for: processObjectID)
            mutedProcessObjectID = processObjectID

            if #available(macOS 14.2, *) {
                let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
                tapDescription.name = "MGQ Original Audio Mute"
                tapDescription.isPrivate = true
                tapDescription.muteBehavior = .muted

                var newTapID = AudioObjectID(kAudioObjectUnknown)
                let status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
                guard status == noErr else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }

                tapID = newTapID
            }

            statusMessage = "Processed-only mode: original app audio muted"
            return true
        } catch {
            statusMessage = "Processed-only mode needs a virtual audio device; macOS denied direct app muting (\(Self.describe(error)))."
            return false
        }
    }

    func unmuteOriginalAudio() {
        if mutedProcessObjectID != kAudioObjectUnknown {
            let restoreValue = previousAudibleValue ?? 1
            try? setProcessAudible(restoreValue != 0, for: mutedProcessObjectID)
            mutedProcessObjectID = AudioObjectID(kAudioObjectUnknown)
            previousAudibleValue = nil
        }

        guard tapID != kAudioObjectUnknown else {
            statusMessage = "Original audio unmuted"
            return
        }

        if #available(macOS 14.2, *) {
            let status = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            statusMessage = status == noErr ? "Original audio unmuted" : "Original audio mute cleanup failed: \(status)"
        }
    }

    private func coreAudioProcessObjectID(for processID: pid_t) throws -> AudioObjectID {
        var pid = processID
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &dataSize,
            &processObjectID
        )

        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status == noErr ? kAudioHardwareBadObjectError : status))
        }

        return processObjectID
    }

    private func processAudibleValue(for processObjectID: AudioObjectID) throws -> UInt32 {
        var value: UInt32 = 1
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var address = processAudibleAddress()

        let status = AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        return value
    }

    private func setProcessAudible(_ audible: Bool, for processObjectID: AudioObjectID) throws {
        var value: UInt32 = audible ? 1 : 0
        var address = processAudibleAddress()
        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(processObjectID, &address, &isSettable)

        guard settableStatus == noErr, isSettable.boolValue else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(settableStatus == noErr ? kAudioHardwareIllegalOperationError : settableStatus))
        }

        let status = AudioObjectSetPropertyData(
            processObjectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )

        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func processAudibleAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessIsAudible,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSOSStatusErrorDomain else {
            return nsError.localizedDescription
        }

        let status = OSStatus(nsError.code)
        if status == kAudioHardwareIllegalOperationError {
            return "illegal operation"
        }

        return "OSStatus \(nsError.code)"
    }
}
