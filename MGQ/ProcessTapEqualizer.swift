import AudioToolbox
import Foundation

final class ProcessTapEqualizer {
    private let queue = DispatchQueue(label: "com.mgq.process-tap", qos: .userInitiated)
    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var eqProcessor: GraphicEQProcessor?
    private var spectrumAnalyzer: SpectrumAnalyzer?
    private var selectedOutputChannels = (left: 0, right: 1)
    private var pendingEQRevision: UInt64 = 0

    private nonisolated(unsafe) var processedBufferCount: UInt64 = 0
    private nonisolated(unsafe) var latestPeak: Float = 0
    private nonisolated(unsafe) var latestOutputPeak: Float = 0
    private nonisolated(unsafe) var inputBufferCount: Int = 0
    private nonisolated(unsafe) var outputBufferCount: Int = 0
    private nonisolated(unsafe) var latestInputChannels: Int = 0
    private nonisolated(unsafe) var latestOutputChannels: Int = 0
    private nonisolated(unsafe) var tapMode = "unknown"
    private nonisolated(unsafe) var isBypassed = false

    var diagnostics: (buffers: UInt64, inputPeak: Float, outputPeak: Float, inputBuffers: Int, outputBuffers: Int, inputChannels: Int, outputChannels: Int, tapMode: String, spectrumLevels: [Float]) {
        (
            processedBufferCount,
            latestPeak,
            latestOutputPeak,
            inputBufferCount,
            outputBufferCount,
            latestInputChannels,
            latestOutputChannels,
            tapMode,
            spectrumAnalyzer?.snapshot() ?? Array(repeating: -72, count: EqualizerBand.graphic31Frequencies.count)
        )
    }

    func start(processObjectIDs: [AudioObjectID], outputDevice: AudioOutputDevice, leftGains: [Float], rightGains: [Float], bypassed: Bool, forceMixdown: Bool = false) throws {
        stop()

        guard !processObjectIDs.isEmpty else {
            throw NSError(domain: "MGQ.ProcessTapEqualizer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Selected app has no CoreAudio process objects"
            ])
        }

        let (tap, newTapID, mode) = try createProcessTap(processObjectIDs: processObjectIDs, outputDevice: outputDevice, forceMixdown: forceMixdown)

        try start(tap: tap, tapID: newTapID, mode: mode, outputDevice: outputDevice, leftGains: leftGains, rightGains: rightGains, bypassed: bypassed)
    }

    func startAllSystemAudio(outputDevice: AudioOutputDevice, leftGains: [Float], rightGains: [Float], bypassed: Bool) throws {
        stop()

        let (tap, newTapID, mode) = try createSystemOutputTap(outputDevice: outputDevice)

        try start(tap: tap, tapID: newTapID, mode: mode, outputDevice: outputDevice, leftGains: leftGains, rightGains: rightGains, bypassed: bypassed)
    }

    private func start(tap: CATapDescription, tapID newTapID: AudioObjectID, mode: String, outputDevice: AudioOutputDevice, leftGains: [Float], rightGains: [Float], bypassed: Bool) throws {
        tapDescription = tap
        tapID = newTapID
        tapMode = mode

        let aggregateDescription = buildAggregateDescription(outputUID: outputDevice.uid, tapUUID: tap.uuid)
        var newAggregateID = AudioObjectID.unknown
        var status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Aggregate output creation failed: \(status)"
            ])
        }

        aggregateDeviceID = newAggregateID
        guard aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            stop()
            throw NSError(domain: "MGQ.ProcessTapEqualizer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Aggregate output did not become ready"
            ])
        }

        let sampleRate = (try? aggregateDeviceID.readNominalSampleRate()) ?? 48_000
        let processor = GraphicEQProcessor(sampleRate: sampleRate, bandCount: EqualizerBand.graphic31Frequencies.count)
        processor.update(leftGains: leftGains, rightGains: rightGains, frequencies: EqualizerBand.graphic31Frequencies, isEnabled: !bypassed)
        eqProcessor = processor
        spectrumAnalyzer = SpectrumAnalyzer(sampleRate: sampleRate, frequencies: EqualizerBand.graphic31Frequencies)
        isBypassed = bypassed
        selectedOutputChannels = outputDevice.id.preferredStereoChannelIndices()
        processedBufferCount = 0
        latestPeak = 0
        latestOutputPeak = 0
        inputBufferCount = 0
        outputBufferCount = 0
        latestInputChannels = 0
        latestOutputChannels = 0

        status = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] _, inputData, _, outputData, _ in
            self?.process(inputData, output: outputData)
        }
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Audio callback creation failed: \(status)"
            ])
        }

        status = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard status == noErr else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Audio callback start failed: \(status)"
            ])
        }
    }

    func stop() {
        pendingEQRevision += 1
        if aggregateDeviceID.isValid, let deviceProcID {
            _ = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
        }
        deviceProcID = nil

        if aggregateDeviceID.isValid {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        aggregateDeviceID = .unknown

        if tapID.isValid {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = .unknown
        tapDescription = nil
        eqProcessor = nil
        spectrumAnalyzer = nil
    }

    func updateEQ(leftGains: [Float], rightGains: [Float], bypassed: Bool) {
        isBypassed = bypassed
        pendingEQRevision += 1
        let revision = pendingEQRevision
        queue.async { [weak self] in
            guard let self, revision == self.pendingEQRevision else { return }
            self.eqProcessor?.update(
                leftGains: leftGains,
                rightGains: rightGains,
                frequencies: EqualizerBand.graphic31Frequencies,
                isEnabled: !bypassed
            )
        }
    }

    private func process(_ inputBufferList: UnsafePointer<AudioBufferList>, output outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        var inputPeak: Float = 0
        var outputPeak: Float = 0
        let localInputBufferCount = inputBuffers.count
        let localOutputBufferCount = outputBuffers.count
        var localInputChannels = 0
        var localOutputChannels = 0

        for outputIndex in 0..<localOutputBufferCount {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)

            let inputIndex: Int
            if localInputBufferCount > localOutputBufferCount {
                inputIndex = localInputBufferCount - localOutputBufferCount + outputIndex
            } else {
                inputIndex = outputIndex
            }

            guard inputIndex < localInputBufferCount else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputBuffer = inputBuffers[inputIndex]
            guard let inputData = inputBuffer.mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let inputChannels = max(1, Int(inputBuffer.mNumberChannels))
            let outputChannels = max(1, Int(outputBuffer.mNumberChannels))
            localInputChannels = inputChannels
            localOutputChannels = outputChannels
            let inputSampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let outputSampleCount = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let inputFrameCount = inputSampleCount / inputChannels
            let frameCount = min(inputFrameCount, outputSampleCount / outputChannels)

            guard frameCount > 0 else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let leftChannel = min(max(selectedOutputChannels.left, 0), max(outputChannels - 1, 0))
            let rightChannel = min(max(selectedOutputChannels.right, 0), max(outputChannels - 1, 0))

            if inputChannels == outputChannels {
                let samplesToCopy = frameCount * inputChannels
                memcpy(outputSamples, inputSamples, samplesToCopy * MemoryLayout<Float>.size)
                if samplesToCopy < outputSampleCount {
                    memset(outputSamples.advanced(by: samplesToCopy), 0, (outputSampleCount - samplesToCopy) * MemoryLayout<Float>.size)
                }
                if inputChannels == 2, outputChannels == 2 {
                    eqProcessor?.process(input: outputSamples, output: outputSamples, frameCount: frameCount)
                }
            } else if inputChannels == 2 && outputChannels > 2 {
                for frame in 0..<frameCount {
                    let inBase = frame * 2
                    let outBase = frame * outputChannels
                    for channel in 0..<outputChannels {
                        outputSamples[outBase + channel] = 0
                    }

                    let left = inputSamples[inBase]
                    let right = inputSamples[inBase + 1]
                    inputPeak = max(inputPeak, abs(left), abs(right))
                    outputSamples[outBase + leftChannel] = left
                    outputSamples[outBase + rightChannel] = right
                }
                
                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            } else if inputChannels == 1 && outputChannels > 1 {
                for frame in 0..<frameCount {
                    let outBase = frame * outputChannels
                    for channel in 0..<outputChannels {
                        outputSamples[outBase + channel] = 0
                    }

                    let sample = inputSamples[frame]
                    inputPeak = max(inputPeak, abs(sample))
                    outputSamples[outBase + leftChannel] = sample
                    outputSamples[outBase + rightChannel] = sample
                }

                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            } else {
                for frame in 0..<frameCount {
                    let inBase = frame * inputChannels
                    let outBase = frame * outputChannels
                    let copiedChannels = min(inputChannels, outputChannels)
                    for channel in 0..<copiedChannels {
                        let sample = inputSamples[inBase + channel]
                        inputPeak = max(inputPeak, abs(sample))
                        outputSamples[outBase + channel] = sample
                    }
                    if copiedChannels < outputChannels {
                        for channel in copiedChannels..<outputChannels {
                            outputSamples[outBase + channel] = 0
                        }
                    }
                }

                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            }

            let writtenSamples = min(outputSampleCount, frameCount * outputChannels)
            spectrumAnalyzer?.process(input: outputSamples, frameCount: frameCount, channels: outputChannels)
            for index in 0..<writtenSamples {
                let value = outputSamples[index]
                outputPeak = max(outputPeak, abs(value))
                if value.isNaN {
                    memset(outputSamples, 0, writtenSamples * MemoryLayout<Float>.size)
                    break
                }
            }
        }

        inputBufferCount = localInputBufferCount
        outputBufferCount = localOutputBufferCount
        latestInputChannels = localInputChannels
        latestOutputChannels = localOutputChannels
        latestPeak = min(max(inputPeak, outputPeak), 1)
        latestOutputPeak = min(outputPeak, 1)
        processedBufferCount += 1
    }

    private func zero(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    private func buildAggregateDescription(outputUID: String, tapUUID: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "MGQpro-\(tapUUID.uuidString.prefix(8))",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
    }

    private func createProcessTap(processObjectIDs: [AudioObjectID], outputDevice: AudioOutputDevice, forceMixdown: Bool) throws -> (CATapDescription, AudioObjectID, String) {
        let defaultOutputUID = AudioDeviceID.defaultOutputDevice().flatMap { try? $0.readDeviceUID() }
        if !forceMixdown,
           defaultOutputUID == outputDevice.uid,
           let streamIndex = try? outputDevice.id.firstOutputStreamIndex() {
            let streamTap = CATapDescription(processes: processObjectIDs, deviceUID: outputDevice.uid, stream: streamIndex)
            streamTap.uuid = UUID()
            streamTap.muteBehavior = .mutedWhenTapped
            streamTap.name = "MGQpro Process Tap"

            var streamTapID = AudioObjectID.unknown
            let streamStatus = AudioHardwareCreateProcessTap(streamTap, &streamTapID)
            if streamStatus == noErr {
                return (streamTap, streamTapID, "stream")
            }
        }

        let mixdownTap = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        mixdownTap.uuid = UUID()
        mixdownTap.muteBehavior = .mutedWhenTapped
        mixdownTap.name = "MGQpro Process Tap"

        var mixdownTapID = AudioObjectID.unknown
        let mixdownStatus = AudioHardwareCreateProcessTap(mixdownTap, &mixdownTapID)
        guard mixdownStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(mixdownStatus), userInfo: [
                NSLocalizedDescriptionKey: "FineTune-style process tap creation failed: \(mixdownStatus)"
            ])
        }

        return (mixdownTap, mixdownTapID, "mixdown")
    }

    private func createSystemOutputTap(outputDevice: AudioOutputDevice) throws -> (CATapDescription, AudioObjectID, String) {
        guard let defaultOutputUID = AudioDeviceID.defaultOutputDevice().flatMap({ try? $0.readDeviceUID() }),
              defaultOutputUID == outputDevice.uid else {
            throw NSError(domain: "MGQ.ProcessTapEqualizer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "All System Audio follows the current macOS output device. Choose the current system output device."
            ])
        }

        let excludedProcesses = currentProcessObjectID().map { [$0] } ?? []
        let streamIndex = try outputDevice.id.firstOutputStreamIndex()
        let streamTap = CATapDescription(excludingProcesses: excludedProcesses, deviceUID: outputDevice.uid, stream: streamIndex)
        streamTap.uuid = UUID()
        streamTap.muteBehavior = .mutedWhenTapped
        streamTap.name = "MGQpro System Output Tap"

        var streamTapID = AudioObjectID.unknown
        let streamStatus = AudioHardwareCreateProcessTap(streamTap, &streamTapID)
        if streamStatus == noErr {
            return (streamTap, streamTapID, "system-stream")
        }

        let globalTap = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        globalTap.uuid = UUID()
        globalTap.muteBehavior = .mutedWhenTapped
        globalTap.name = "MGQpro System Mix Tap"

        var globalTapID = AudioObjectID.unknown
        let globalStatus = AudioHardwareCreateProcessTap(globalTap, &globalTapID)
        guard globalStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(globalStatus), userInfo: [
                NSLocalizedDescriptionKey: "System output tap creation failed: \(globalStatus)"
            ])
        }

        return (globalTap, globalTapID, "system-mixdown")
    }

    private func currentProcessObjectID() -> AudioObjectID? {
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var processObjectID = AudioObjectID.unknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let pidSize = UInt32(MemoryLayout<pid_t>.size)
        var objectSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID.system, &address, pidSize, &pid, &objectSize, &processObjectID)
        return status == noErr && processObjectID.isValid ? processObjectID : nil
    }
}
