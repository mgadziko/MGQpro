import Foundation
import AppKit
import AudioToolbox
import CoreMedia
import Darwin
import ScreenCaptureKit

@MainActor
final class AppAudioCaptureManager: ObservableObject {
    @Published var runningApps: [RunningAudioApp] = []
    @Published var selectedAppID: RunningAudioApp.ID?
    @Published var statusMessage = "Idle"

    var selectedApp: RunningAudioApp? {
        guard let selectedAppID else { return nil }
        return runningApps.first { $0.id == selectedAppID }
    }

    private var stream: SCStream?
    private var streamOutput: AppAudioStreamOutput?
    private let captureQueue = DispatchQueue(label: "com.mgq.capture.audio")
    private static let systemDaemonPrefixes = [
        "com.apple.siri",
        "com.apple.Siri",
        "com.apple.assistant",
        "com.apple.audio",
        "com.apple.coreaudio",
        "com.apple.mediaremote",
        "com.apple.systemsound",
        "com.apple.notificationcenter",
        "com.apple.NotificationCenter",
        "com.apple.UserNotifications",
        "com.apple.usernotifications"
    ]
    private static let systemDaemonNames = [
        "systemsoundserverd",
        "systemsoundserv",
        "coreaudiod",
        "audiomxd"
    ]

    func refreshRunningApps() async {
        do {
            let processObjects = try AudioObjectID.readProcessList()
            let workspaceApps = NSWorkspace.shared.runningApplications
            let runningAppsByPID = Dictionary(
                workspaceApps.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let myPID = ProcessInfo.processInfo.processIdentifier
            var appsByPID: [pid_t: RunningAudioApp] = [:]

            for objectID in processObjects {
                guard let pid = try? objectID.readProcessPID(), pid > 0, pid != myPID else { continue }
                guard objectID.readProcessIsRunning() else { continue }

                let directApp = runningAppsByPID[pid]
                let isRealApp = directApp?.bundleURL?.pathExtension == "app"
                let resolvedApp = isRealApp ? directApp : findResponsibleApp(for: pid, in: runningAppsByPID)
                let parentPID = resolvedApp?.processIdentifier ?? pid
                let name = resolvedApp?.localizedName
                    ?? objectID.readProcessBundleID()?.components(separatedBy: ".").last
                    ?? "Unknown"
                let bundleID = resolvedApp?.bundleIdentifier ?? objectID.readProcessBundleID()

                if isSystemDaemon(bundleID: bundleID, name: name) { continue }

                if let existing = appsByPID[parentPID] {
                    var merged = existing.processObjectIDs
                    if !merged.contains(objectID) {
                        merged.append(objectID)
                        merged.sort()
                    }
                    appsByPID[parentPID] = RunningAudioApp(
                        id: "\(parentPID)-\(merged.map(String.init).joined(separator: "-"))",
                        processID: parentPID,
                        processObjectIDs: merged,
                        name: existing.name,
                        bundleIdentifier: existing.bundleIdentifier
                    )
                } else {
                    appsByPID[parentPID] = RunningAudioApp(
                        id: "\(parentPID)-\(objectID)",
                        processID: parentPID,
                        processObjectIDs: [objectID],
                        name: name,
                        bundleIdentifier: bundleID
                    )
                }
            }

            let audioApps = appsByPID.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            runningApps = audioApps
            if let selectedAppID, audioApps.contains(where: { $0.id == selectedAppID }) {
                self.selectedAppID = selectedAppID
            } else {
                selectedAppID = audioApps.first?.id
            }
            statusMessage = audioApps.isEmpty ? "No CoreAudio app audio found" : "Found \(audioApps.count) audio apps"
        } catch {
            statusMessage = "Audio app refresh failed: \(error.localizedDescription)"
        }
    }

    private func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        if let bundleID,
           Self.systemDaemonPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }

        let lowercaseName = name.lowercased()
        return Self.systemDaemonNames.contains { lowercaseName.hasPrefix($0) }
    }

    private func findResponsibleApp(for pid: pid_t, in runningAppsByPID: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        if let responsiblePID = responsiblePID(for: pid),
           let app = runningAppsByPID[responsiblePID],
           app.bundleURL?.pathExtension == "app" {
            return app
        }

        var currentPID = pid
        var visited = Set<pid_t>()

        while currentPID > 1 && !visited.contains(currentPID) {
            visited.insert(currentPID)

            if let app = runningAppsByPID[currentPID],
               app.bundleURL?.pathExtension == "app" {
                return app
            }

            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, currentPID]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }

            let parentPID = info.kp_eproc.e_ppid
            if parentPID == currentPID { break }
            currentPID = parentPID
        }

        return nil
    }

    private func responsiblePID(for pid: pid_t) -> pid_t? {
        typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }

        let resolvedPID = unsafeBitCast(symbol, to: ResponsibilityFunction.self)(pid)
        return resolvedPID > 0 && resolvedPID != pid ? resolvedPID : nil
    }

    func requestScreenCaptureAccess() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            statusMessage = "Screen/audio capture permission available"
        } catch {
            statusMessage = "Grant Screen Recording permission in System Settings, then relaunch MGQpro"
        }
    }

    @discardableResult
    func startCapturingSelectedApp(audioSink: @escaping @MainActor (CMSampleBuffer) -> Void) async -> Bool {
        guard let selectedAppID,
              let selectedApp = runningApps.first(where: { $0.id == selectedAppID }) else {
            statusMessage = "Choose an input app"
            return false
        }

        do {
            try await stopCapture()

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                statusMessage = "No display available for ScreenCaptureKit filter"
                return false
            }
            guard let captureApp = content.applications.first(where: { $0.processID == selectedApp.processID }) else {
                statusMessage = "\(selectedApp.name) is not currently capturable"
                return false
            }

            let filter = SCContentFilter(display: display, including: [captureApp], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let output = AppAudioStreamOutput(audioSink: audioSink)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()

            self.streamOutput = output
            self.stream = stream
            statusMessage = "Capturing \(selectedApp.name)"
            return true
        } catch {
            statusMessage = "Capture failed: \(error.localizedDescription)"
            return false
        }
    }

    func stopCapture() async throws {
        if let stream {
            try await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        statusMessage = "Capture stopped"
    }
}

private final class AppAudioStreamOutput: NSObject, SCStreamOutput {
    private let audioSink: @MainActor (CMSampleBuffer) -> Void

    init(audioSink: @escaping @MainActor (CMSampleBuffer) -> Void) {
        self.audioSink = audioSink
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        Task { @MainActor in
            audioSink(sampleBuffer)
        }
    }
}
