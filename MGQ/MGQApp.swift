import SwiftUI

@main
struct MGQApp: App {
    @StateObject private var audioDeviceManager = AudioDeviceManager()
    @StateObject private var captureManager = AppAudioCaptureManager()
    @StateObject private var equalizerEngine = EqualizerEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioDeviceManager)
                .environmentObject(captureManager)
                .environmentObject(equalizerEngine)
                .task {
                    await captureManager.refreshRunningApps()
                    audioDeviceManager.refreshOutputDevices()
                    equalizerEngine.configureDefaultBands()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Load Profile...") {
                    equalizerEngine.loadProfileFromDisk()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Save Profile...") {
                    equalizerEngine.saveProfileToDisk()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }
}
