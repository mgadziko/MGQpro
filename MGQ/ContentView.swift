import SwiftUI
import CoreAudio

struct ContentView: View {
    @EnvironmentObject private var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject private var captureManager: AppAudioCaptureManager
    @EnvironmentObject private var equalizerEngine: EqualizerEngine

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 14) {
                TopControlBar()

                EqualizerSliders(sliderHeight: sliderHeight(for: geometry.size.height))

                BottomControlBar()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 920, idealWidth: 1_060, minHeight: 820, idealHeight: 1_040)
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            equalizerEngine.refreshDiagnostics()
        }
    }

    private func sliderHeight(for windowHeight: CGFloat) -> CGFloat {
        min(280, max(210, (windowHeight - 280) / 2))
    }
}

private struct TopControlBar: View {
    @EnvironmentObject private var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject private var captureManager: AppAudioCaptureManager
    @EnvironmentObject private var equalizerEngine: EqualizerEngine

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                controls
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    inputControls
                    outputPicker
                }
                HStack(spacing: 16) {
                    actionButtons
                }
            }
        }
    }

    private var controls: some View {
        Group {
            inputControls
            outputPicker
            actionButtons
        }
    }

    private var inputControls: some View {
        Group {
            Picker("Input", selection: $equalizerEngine.inputMode) {
                ForEach(AudioInputMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .frame(minWidth: 170)

            if equalizerEngine.inputMode == .application {
                Picker("Input App", selection: $captureManager.selectedAppID) {
                    ForEach(captureManager.runningApps) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                .frame(minWidth: 220)
            }
        }
    }

    private var outputPicker: some View {
        Picker("Output Device", selection: $audioDeviceManager.selectedOutputDeviceID) {
            ForEach(audioDeviceManager.outputDevices) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }
        .frame(minWidth: 240)
    }

    private var actionButtons: some View {
        Group {
            Button("Refresh") {
                Task {
                    await captureManager.refreshRunningApps()
                    audioDeviceManager.refreshOutputDevices()
                }
            }

            Button(equalizerEngine.isRunning ? "Stop" : "Start") {
                if equalizerEngine.isRunning {
                    equalizerEngine.stop()
                } else {
                    let outputDevice = audioDeviceManager.outputDevices.first { $0.id == audioDeviceManager.selectedOutputDeviceID }
                    equalizerEngine.start(inputMode: equalizerEngine.inputMode, selectedApp: captureManager.selectedApp, outputDevice: outputDevice)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
        }
    }
}

private struct BottomControlBar: View {
    @EnvironmentObject private var captureManager: AppAudioCaptureManager
    @EnvironmentObject private var equalizerEngine: EqualizerEngine

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                controls
                Spacer(minLength: 12)
                status
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    controls
                }
                status
            }
        }
        .font(.callout)
    }

    private var controls: some View {
        Group {
            Button("Reset EQ") {
                equalizerEngine.resetBands()
            }

            Toggle("LR Tandem", isOn: $equalizerEngine.isLRTandem)
                .toggleStyle(.checkbox)

            Toggle("Bypass EQ", isOn: $equalizerEngine.isEQBypassed)
                .toggleStyle(.checkbox)

            Toggle("Open on Startup", isOn: Binding {
                equalizerEngine.openAtStartup
            } set: { enabled in
                equalizerEngine.setOpenAtStartup(enabled)
            })
            .toggleStyle(.checkbox)
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            Text(captureManager.statusMessage)
            Text(equalizerEngine.statusMessage)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct EqualizerSliders: View {
    let sliderHeight: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            ChannelEqualizer(channel: .left, sliderHeight: sliderHeight)
            Divider()
            ChannelEqualizer(channel: .right, sliderHeight: sliderHeight)
        }
    }
}

private struct ChannelEqualizer: View {
    @EnvironmentObject private var equalizerEngine: EqualizerEngine
    let channel: EQChannel
    let sliderHeight: CGFloat
    private let scaleWidth: CGFloat = 42
    private let bandSpacing: CGFloat = 4
    private let vuLegendWidth: CGFloat = 38
    private let guideValues: [Float] = [9, 6, 3, 0, -3, -6, -9]
    private let vuLegendValues: [Float] = [12, 9, 6, 3, 0, -3, -6, -9, -12, -18, -24, -36, -48, -60]

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(channel.displayName)
                    .font(.headline)
                Spacer()
            }

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 2) {
                    GainScale(values: guideValues)
                        .frame(width: scaleWidth, height: sliderHeight)

                    Color.clear
                        .frame(height: 16)
                }
                .frame(width: scaleWidth)

                ZStack(alignment: .top) {
                    GainGrid(values: guideValues, height: sliderHeight)

                    HStack(alignment: .top, spacing: bandSpacing) {
                        ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                            VStack(spacing: 2) {
                                ZStack {
                                    SpectrumLEDColumn(levelDB: spectrumLevel(for: band.id))

                                    VerticalGainFader(
                                        gain: binding(for: band.id),
                                        height: sliderHeight
                                    )
                                }
                                .frame(maxWidth: .infinity, minHeight: sliderHeight, maxHeight: sliderHeight)

                                Text(band.displayFrequency)
                                    .font(.caption2.monospacedDigit())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.55)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 16)
                            }
                            .frame(maxWidth: .infinity)

                            if index == bands.count - 1 {
                                VStack(spacing: 2) {
                                    VULegend(values: vuLegendValues)
                                        .frame(width: vuLegendWidth, height: sliderHeight)

                                    Color.clear
                                        .frame(width: vuLegendWidth, height: 16)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: sliderHeight + 18, maxHeight: sliderHeight + 18)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var bands: [EqualizerBand] {
        switch channel {
        case .left:
            return equalizerEngine.leftBands
        case .right:
            return equalizerEngine.rightBands
        }
    }

    private func binding(for bandID: EqualizerBand.ID) -> Binding<Float> {
        Binding {
            bands.first(where: { $0.id == bandID })?.gain ?? 0
        } set: { newValue in
            equalizerEngine.updateGain(for: channel, bandID: bandID, gain: snappedGain(newValue))
        }
    }

    private func snappedGain(_ value: Float) -> Float {
        let rounded = (value * 2).rounded() / 2
        let snapTargets: [Float] = [-9, -6, -3, 0, 3, 6, 9]
        if let target = snapTargets.min(by: { abs($0 - rounded) < abs($1 - rounded) }),
           abs(target - rounded) <= 0.35 {
            return target
        }
        return min(12, max(-12, rounded))
    }

    private func spectrumLevel(for bandID: EqualizerBand.ID) -> Float {
        equalizerEngine.spectrumLevels.indices.contains(bandID) ? equalizerEngine.spectrumLevels[bandID] : -72
    }
}

private struct GainScale: View {
    let values: [Float]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                ForEach(values, id: \.self) { value in
                    Text(label(for: value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(value == 0 ? .primary : .secondary)
                        .position(x: 16, y: yPosition(for: value, height: geometry.size.height))
                }
            }
        }
    }

    private func label(for value: Float) -> String {
        value > 0 ? "+\(Int(value))" : "\(Int(value))"
    }

    private func yPosition(for gain: Float, height: CGFloat) -> CGFloat {
        CGFloat((12 - gain) / 24) * height
    }
}

private struct GainGrid: View {
    let values: [Float]
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(values, id: \.self) { value in
                    Rectangle()
                        .fill(value == 0 ? Color.primary.opacity(0.35) : Color.secondary.opacity(0.22))
                        .frame(width: geometry.size.width, height: value == 0 ? 1.5 : 1)
                        .position(x: geometry.size.width / 2, y: yPosition(for: value))
                }
            }
        }
        .frame(height: height)
    }

    private func yPosition(for gain: Float) -> CGFloat {
        CGFloat((12 - gain) / 24) * height
    }
}

private struct SpectrumLEDColumn: View {
    let levelDB: Float
    private let minimumDB: Float = -60
    private let maximumDB: Float = 12
    private let segmentDB: Float = 1
    private let segmentSpacing: CGFloat = 2

    private var segmentCount: Int {
        Int((maximumDB - minimumDB) / segmentDB)
    }

    var body: some View {
        Canvas { context, size in
            let segmentHeight = segmentHeight(in: size.height)
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3),
                with: .color(Color.black.opacity(0.18))
            )

            for index in 0..<segmentCount {
                let threshold = minimumDB + Float(index) * segmentDB
                let reversedIndex = segmentCount - 1 - index
                let y = CGFloat(reversedIndex) * (segmentHeight + segmentSpacing)
                let rect = CGRect(
                    x: 1,
                    y: y,
                    width: max(1, size.width - 2),
                    height: segmentHeight
                )
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                context.fill(path, with: .color(color(for: threshold).opacity(levelDB >= threshold ? 0.96 : 0.12)))
                context.stroke(path, with: .color(Color.black.opacity(0.28)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func segmentHeight(in totalHeight: CGFloat) -> CGFloat {
        max(1, (totalHeight - CGFloat(segmentCount - 1) * segmentSpacing) / CGFloat(segmentCount))
    }

    private func color(for threshold: Float) -> Color {
        if threshold > 0 {
            return Color(red: 1.0, green: 0.12, blue: 0.08)
        }
        if threshold >= -24 {
            return Color(red: 1.0, green: 0.88, blue: 0.05)
        }
        return Color(red: 0.1, green: 1.0, blue: 0.16)
    }
}

private struct VULegend: View {
    let values: [Float]
    private let minimumDB: Float = -60
    private let maximumDB: Float = 12

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 1)
                    .position(x: 4, y: geometry.size.height / 2)

                ForEach(values, id: \.self) { value in
                    HStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.58))
                            .frame(width: 7, height: 1)
                        Text(label(for: value))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(color(for: value))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .position(x: geometry.size.width / 2, y: yPosition(for: value, height: geometry.size.height))
                }
            }
        }
    }

    private func label(for value: Float) -> String {
        value > 0 ? "+\(Int(value))" : "\(Int(value))"
    }

    private func yPosition(for value: Float, height: CGFloat) -> CGFloat {
        let clamped = min(maximumDB, max(minimumDB, value))
        return CGFloat((maximumDB - clamped) / (maximumDB - minimumDB)) * height
    }

    private func color(for value: Float) -> Color {
        if value >= 9 {
            return Color(red: 1.0, green: 0.26, blue: 0.18)
        }
        if value >= 6 {
            return Color(red: 1.0, green: 0.86, blue: 0.15)
        }
        return .secondary
    }
}

private struct VerticalGainFader: View {
    @Binding var gain: Float
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 4, height: geometry.size.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.65), lineWidth: 1)
                    )
                    .shadow(radius: 1, y: 1)
                    .position(x: geometry.size.width / 2, y: yPosition(for: gain, height: geometry.size.height))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        gain = gainValue(for: value.location.y, height: geometry.size.height)
                    }
            )
            .accessibilityLabel("Gain")
            .accessibilityValue("\(gain, specifier: "%.1f") dB")
        }
    }

    private func yPosition(for gain: Float, height: CGFloat) -> CGFloat {
        CGFloat((12 - gain) / 24) * height
    }

    private func gainValue(for y: CGFloat, height: CGFloat) -> Float {
        let clampedY = min(height, max(0, y))
        return Float(12 - (clampedY / height) * 24)
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioDeviceManager())
        .environmentObject(AppAudioCaptureManager())
        .environmentObject(EqualizerEngine())
}
