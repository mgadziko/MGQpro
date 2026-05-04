import AppKit
import CoreAudio
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

private struct StereoEQProfile: Codable {
    var left: [Float]
    var right: [Float]
}

@MainActor
final class EqualizerEngine: ObservableObject {
    @Published var leftBands: [EqualizerBand] = []
    @Published var rightBands: [EqualizerBand] = []
    @Published var inputMode: AudioInputMode = .systemOutput
    @Published var isLRTandem = true
    @Published var isRunning = false
    @Published var isEQBypassed = false {
        didSet {
            processTapEqualizer.updateEQ(leftGains: leftBandGains, rightGains: rightBandGains, bypassed: isEQBypassed)
            updateStatusMessage()
        }
    }
    @Published var processedBufferCount = 0
    @Published var lastInputPeakDB: Float = -.infinity
    @Published var lastOutputPeakDB: Float = -.infinity
    @Published var bufferFormatSummary = ""
    @Published var statusMessage = "Audio engine stopped"
    @Published var spectrumLevels: [Float] = Array(repeating: -72, count: EqualizerBand.graphic31Frequencies.count)
    @Published var openAtStartup = false

    private let processTapEqualizer = ProcessTapEqualizer()
    private var activeApp: RunningAudioApp?
    private var activeOutputDevice: AudioOutputDevice?
    private var activeInputMode: AudioInputMode = .systemOutput
    private var forcedMixdownFallback = false
    private let gainsKey = "MGQpro.currentBandGains"
    private let defaultProfileDirectoryName = "MGQpro"

    init() {
        createDefaultProfileDirectoryIfNeeded()
        openAtStartup = SMAppService.mainApp.status == .enabled
    }

    func configureDefaultBands() {
        guard leftBands.isEmpty, rightBands.isEmpty else { return }
        let savedGains = loadCurrentGains()
        leftBands = EqualizerBand.graphic31Frequencies.enumerated().map { index, frequency in
            let savedGain = savedGains.left.indices.contains(index) ? savedGains.left[index] : 0
            return EqualizerBand(id: index, frequency: frequency, gain: savedGain)
        }
        rightBands = EqualizerBand.graphic31Frequencies.enumerated().map { index, frequency in
            let savedGain = savedGains.right.indices.contains(index) ? savedGains.right[index] : 0
            return EqualizerBand(id: index, frequency: frequency, gain: savedGain)
        }
    }

    func updateGain(for channel: EQChannel, bandID: EqualizerBand.ID, gain: Float) {
        guard leftBands.indices.contains(bandID), rightBands.indices.contains(bandID) else { return }
        switch channel {
        case .left:
            leftBands[bandID].gain = gain
            if isLRTandem {
                rightBands[bandID].gain = gain
            }
        case .right:
            rightBands[bandID].gain = gain
            if isLRTandem {
                leftBands[bandID].gain = gain
            }
        }
        persistCurrentGains()
        processTapEqualizer.updateEQ(leftGains: leftBandGains, rightGains: rightBandGains, bypassed: isEQBypassed)
    }

    func resetBands() {
        for index in leftBands.indices {
            leftBands[index].gain = 0
        }
        for index in rightBands.indices {
            rightBands[index].gain = 0
        }
        persistCurrentGains()
        processTapEqualizer.updateEQ(leftGains: leftBandGains, rightGains: rightBandGains, bypassed: isEQBypassed)
    }

    func saveProfileToDisk() {
        createDefaultProfileDirectoryIfNeeded()

        let panel = NSSavePanel()
        panel.title = "Save MGQpro Profile"
        panel.nameFieldStringValue = "MGQpro Profile.json"
        panel.canCreateDirectories = true
        panel.directoryURL = defaultProfileDirectoryURL
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let profile = StereoEQProfile(left: leftBandGains, right: rightBandGains)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            try data.write(to: url, options: .atomic)
            statusMessage = "Saved profile \(url.lastPathComponent)"
        } catch {
            statusMessage = "Save profile failed: \(error.localizedDescription)"
        }
    }

    func loadProfileFromDisk() {
        createDefaultProfileDirectoryIfNeeded()

        let panel = NSOpenPanel()
        panel.title = "Load MGQpro Profile"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultProfileDirectoryURL
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let profile = try JSONDecoder().decode(StereoEQProfile.self, from: data)
            try applyProfile(profile)
            statusMessage = "Loaded profile \(url.lastPathComponent)"
        } catch {
            statusMessage = "Load profile failed: \(error.localizedDescription)"
        }
    }

    func setOpenAtStartup(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            openAtStartup = SMAppService.mainApp.status == .enabled
        } catch {
            openAtStartup = SMAppService.mainApp.status == .enabled
            statusMessage = "Open on Startup failed: \(error.localizedDescription)"
        }
    }

    func start(inputMode: AudioInputMode, selectedApp: RunningAudioApp?, outputDevice: AudioOutputDevice?) {
        guard let outputDevice else {
            statusMessage = "Choose an output device"
            return
        }

        do {
            activeInputMode = inputMode
            activeApp = selectedApp
            activeOutputDevice = outputDevice
            forcedMixdownFallback = false
            switch inputMode {
            case .systemOutput:
                try processTapEqualizer.startAllSystemAudio(
                    outputDevice: outputDevice,
                    leftGains: leftBandGains,
                    rightGains: rightBandGains,
                    bypassed: isEQBypassed
                )
            case .application:
                guard let selectedApp else {
                    statusMessage = "Choose an input app"
                    return
                }
                try processTapEqualizer.start(
                    processObjectIDs: selectedApp.processObjectIDs,
                    outputDevice: outputDevice,
                    leftGains: leftBandGains,
                    rightGains: rightBandGains,
                    bypassed: isEQBypassed,
                    forceMixdown: false
                )
            }
            processedBufferCount = 0
            lastInputPeakDB = -.infinity
            lastOutputPeakDB = -.infinity
            spectrumLevels = Array(repeating: -72, count: EqualizerBand.graphic31Frequencies.count)
            switch inputMode {
            case .systemOutput:
                bufferFormatSummary = "all audio to \(outputDevice.name)"
            case .application:
                let processCount = selectedApp?.processObjectIDs.count ?? 0
                bufferFormatSummary = "\(processCount) audio process\(processCount == 1 ? "" : "es")"
            }
            isRunning = true
            updateStatusMessage()
        } catch {
            isRunning = false
            statusMessage = "Audio tap failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        processTapEqualizer.stop()
        activeApp = nil
        activeOutputDevice = nil
        activeInputMode = .systemOutput
        forcedMixdownFallback = false
        isRunning = false
        statusMessage = "Audio engine stopped"
    }

    func refreshDiagnostics() {
        guard isRunning else { return }
        let diagnostics = processTapEqualizer.diagnostics
        if diagnostics.tapMode == "stream",
           diagnostics.buffers > 20,
           diagnostics.inputPeak == 0,
           diagnostics.outputPeak == 0,
           !forcedMixdownFallback {
            restartWithMixdownFallback()
            return
        }

        processedBufferCount = Int(diagnostics.buffers)
        lastInputPeakDB = diagnostics.inputPeak > 0 ? 20 * log10(diagnostics.inputPeak) : -.infinity
        lastOutputPeakDB = diagnostics.outputPeak > 0 ? 20 * log10(diagnostics.outputPeak) : -.infinity
        spectrumLevels = diagnostics.spectrumLevels
        bufferFormatSummary = "\(diagnostics.tapMode), in \(diagnostics.inputBuffers)x\(diagnostics.inputChannels), out \(diagnostics.outputBuffers)x\(diagnostics.outputChannels)"
        updateStatusMessage()
    }

    private func updateStatusMessage() {
        guard isRunning else {
            statusMessage = "Audio engine stopped"
            return
        }

        let mode = isEQBypassed ? "bypassed" : "EQ active"
        if processedBufferCount == 0 {
            statusMessage = "\(mode), waiting for captured audio"
        } else if lastOutputPeakDB.isFinite {
            statusMessage = "\(mode), \(bufferFormatSummary), out \(Int(lastOutputPeakDB.rounded())) dB"
        } else if lastInputPeakDB.isFinite {
            statusMessage = "\(mode), \(bufferFormatSummary), input \(Int(lastInputPeakDB.rounded())) dB but silent output"
        } else {
            statusMessage = "\(mode), \(bufferFormatSummary), silent tap"
        }
    }

    private var leftBandGains: [Float] {
        leftBands.map(\.gain)
    }

    private var rightBandGains: [Float] {
        rightBands.map(\.gain)
    }

    private func persistCurrentGains() {
        let profile = StereoEQProfile(left: leftBandGains, right: rightBandGains)
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: gainsKey)
    }

    private func loadCurrentGains() -> StereoEQProfile {
        if let data = UserDefaults.standard.data(forKey: gainsKey),
           let gains = try? JSONDecoder().decode(StereoEQProfile.self, from: data) {
            return gains
        }

        if let oldGains = UserDefaults.standard.array(forKey: gainsKey) as? [Double] {
            let monoGains = oldGains.map(Float.init)
            return StereoEQProfile(left: monoGains, right: monoGains)
        }

        return StereoEQProfile(left: [], right: [])
    }

    private var defaultProfileDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(defaultProfileDirectoryName, isDirectory: true)
    }

    private func createDefaultProfileDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: defaultProfileDirectoryURL, withIntermediateDirectories: true)
    }

    private func applyProfile(_ profile: StereoEQProfile) throws {
        guard profile.left.count == leftBands.count,
              profile.right.count == rightBands.count else {
            throw NSError(domain: "MGQpro.Profile", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Profile does not contain 31 left and 31 right EQ bands."
            ])
        }

        for index in leftBands.indices {
            leftBands[index].gain = min(12, max(-12, profile.left[index]))
        }
        for index in rightBands.indices {
            rightBands[index].gain = min(12, max(-12, profile.right[index]))
        }
        persistCurrentGains()
        processTapEqualizer.updateEQ(leftGains: leftBandGains, rightGains: rightBandGains, bypassed: isEQBypassed)
    }

    private func restartWithMixdownFallback() {
        guard activeInputMode == .application, let activeApp, let activeOutputDevice else { return }

        forcedMixdownFallback = true
        do {
            try processTapEqualizer.start(
                processObjectIDs: activeApp.processObjectIDs,
                outputDevice: activeOutputDevice,
                leftGains: leftBandGains,
                rightGains: rightBandGains,
                bypassed: isEQBypassed,
                forceMixdown: true
            )
            processedBufferCount = 0
            lastInputPeakDB = -.infinity
            lastOutputPeakDB = -.infinity
            spectrumLevels = Array(repeating: -72, count: EqualizerBand.graphic31Frequencies.count)
            bufferFormatSummary = "mixdown fallback"
            statusMessage = "Stream tap was silent, retrying mixdown"
        } catch {
            isRunning = false
            statusMessage = "Mixdown fallback failed: \(error.localizedDescription)"
        }
    }
}
