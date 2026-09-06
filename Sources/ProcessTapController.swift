import AudioToolbox
import Foundation
import os

/// Controls audio processing for a single app via CoreAudio process tap.
/// Uses an aggregate device with an IO callback for real-time volume/mute control.
@available(macOS 14.2, *)
final class ProcessTapController {
    let pid: pid_t
    let processObjectID: AudioObjectID
    private let logger: Logger
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)

    // MARK: - RT-Safe State

    /// Target volume set by user (0.0-3.0, where 1.0 = unity gain)
    private nonisolated(unsafe) var _volume: Float = 1.0
    /// Current ramped volume (smoothly approaches _volume)
    private nonisolated(unsafe) var _currentVolume: Float = 1.0
    /// User-controlled mute - outputs silence
    private nonisolated(unsafe) var _isMuted: Bool = false
    /// Lightweight RMS meter used by the generic communication compensator.
    private nonisolated(unsafe) var _measuredRMSLevel: Float = 0

    // MARK: - Non-RT State

    /// Volume ramp coefficient (30ms ramp at 48kHz prevents clicks)
    private var rampCoefficient: Float = 0.0007

    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var activated = false
    private var outputDeviceID: AudioObjectID = .unknown
    private var lastDuckingResult: String?

    // MARK: - Public Properties

    var volume: Float {
        get { _volume }
        set { _volume = max(0, min(3.0, newValue)) }
    }

    var isMuted: Bool {
        get { _isMuted }
        set { _isMuted = newValue }
    }

    var measuredRMSLevel: Float {
        _measuredRMSLevel
    }

    // MARK: - Initialization

    init?(pid: pid_t) {
        guard let processObjectID = Self.findProcessObjectID(for: pid) else {
            return nil
        }

        self.pid = pid
        self.processObjectID = processObjectID
        self.logger = Logger(subsystem: "MacVolume", category: "ProcessTapController(\(pid))")
    }

    deinit {
        invalidate()
    }

    // MARK: - Lifecycle

    func activate() throws {
        guard !activated else { return }

        // CATapDescription produces stereo Float32 interleaved audio from the target process.
        // mutedWhenTapped ensures the app's audio goes through our tap, not directly to output.
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped
        self.tapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }

        processTapID = tapID

        guard let defaultDeviceUID = getDefaultOutputDeviceUID() else {
            cleanupPartialActivation()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No default output device"])
        }

        let description = buildAggregateDescription(
            outputUID: defaultDeviceUID,
            tapUUID: tapDesc.uuid,
            name: "MacVolume-\(pid)"
        )

        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(err)"])
        }

        guard aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            cleanupPartialActivation()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aggregate device not ready within timeout"])
        }

        // Compute ramp coefficient from device sample rate
        let sampleRate: Float64
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
        } else {
            sampleRate = 48000
        }
        let rampTimeSeconds: Float = 0.030
        rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))

        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        _currentVolume = _volume
        activated = true
        logger.info("Tap activated for PID \(self.pid)")
    }

    func invalidate() {
        guard activated else { return }
        activated = false

        let primaryAggregate = aggregateDeviceID
        let primaryProcID = deviceProcID
        let primaryTap = processTapID

        aggregateDeviceID = .unknown
        deviceProcID = nil
        processTapID = .unknown
        tapDescription = nil

        DispatchQueue.global(qos: .utility).async {
            Self.destroyTap(aggregateID: primaryAggregate, deviceProcID: primaryProcID, tapID: primaryTap)
        }
    }

    // MARK: - Private Implementation

    private static func findProcessObjectID(for pid: pid_t) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize) == noErr else { return nil }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        var objectList = [AudioObjectID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &objectList) == noErr else { return nil }

        for objectID in objectList {
            var processPID: pid_t = 0
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pidSize = UInt32(MemoryLayout<pid_t>.size)

            if AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                if processPID == pid {
                    return objectID
                }
            }
        }
        return nil
    }

    private func getDefaultOutputDeviceUID() -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        outputDeviceID = deviceID

        propertyAddress.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString>.size)

        let uidStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &uid
        )

        guard uidStatus == noErr, let cfUID = uid else { return nil }
        return cfUID.takeRetainedValue() as String
    }

    private func buildAggregateDescription(outputUID: String, tapUUID: UUID, name: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: name,
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
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }

    private func cleanupPartialActivation() {
        if let procID = deviceProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if processTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
        }
    }

    private static func destroyTap(aggregateID: AudioObjectID, deviceProcID: AudioDeviceIOProcID?, tapID: AudioObjectID) {
        if let procID = deviceProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    /// The undocumented HAL 'duck' property is capability-checked on each device.
    /// Never amplify samples if it is absent or rejected. Run off the audio callback.
    /// This clears transient ducking only; it does not change hardware/user volume.
    func restoreDeviceDucking() {
        guard activated else { return }
        var results: [String] = []
        for device in [outputDeviceID, aggregateDeviceID] where device != .unknown {
            for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
                var address = AudioObjectPropertyAddress(
                    mSelector: 0x6475636B, // 'duck', not a documented SDK constant
                    mScope: scope, mElement: kAudioObjectPropertyElementMain
                )
                guard AudioObjectHasProperty(device, &address) else { continue }
                var settable: DarwinBoolean = false
                var size: UInt32 = 0
                guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                      settable.boolValue,
                      AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
                      size == 4 * MemoryLayout<Float32>.size else { continue }
                var current = [Float32](repeating: 0, count: 4)
                let readStatus = current.withUnsafeMutableBytes {
                    AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)
                }
                guard readStatus == noErr, current.allSatisfy({ $0.isFinite }) else { continue }
                // Avoid writing an unchanged property every half second.
                let unity: [Float32] = [1, 0, 0, 0]
                let status: OSStatus = current == unity ? noErr : unity.withUnsafeBytes {
                    AudioObjectSetPropertyData(device, &address, 0, nil, size, $0.baseAddress!)
                }
                results.append("\(device)/\(scope):\(status)")
            }
        }
        let result = results.isEmpty ? "unsupported; unity-gain routing only" : results.joined(separator: ",")
        if result != lastDuckingResult {
            logger.info("Device ducking restore: \(result)")
            lastDuckingResult = result
        }
    }

    // MARK: - RT-Safe Audio Callback

    private func processAudio(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        if _isMuted {
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        let targetVol = _volume
        var currentVol = _currentVolume

        let inputBufferCount = inputBuffers.count
        let outputBufferCount = outputBuffers.count
        var levelSumSquares: Float = 0
        var levelSampleCount = 0

        for outputIndex in 0..<outputBufferCount {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }

            let inputIndex: Int
            if inputBufferCount > outputBufferCount {
                inputIndex = inputBufferCount - outputBufferCount + outputIndex
            } else {
                inputIndex = outputIndex
            }

            guard inputIndex < inputBufferCount else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputBuffer = inputBuffers[inputIndex]
            guard let inputData = inputBuffer.mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let inputSampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let outputSampleCount = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let count = min(inputSampleCount, outputSampleCount)

            for i in 0..<count {
                currentVol += (targetVol - currentVol) * rampCoefficient
                let inputSample = inputSamples[i]
                levelSumSquares += inputSample * inputSample
                levelSampleCount += 1
                outputSamples[i] = Self.renderSample(inputSample, gain: currentVol)
            }
        }

        _currentVolume = currentVol
        if levelSampleCount > 0 {
            let frameRMS = sqrt(levelSumSquares / Float(levelSampleCount))
            _measuredRMSLevel = (_measuredRMSLevel * 0.85) + (frameRMS * 0.15)
        }
    }

    /// Unity/attenuation preserve the waveform, including near-full-scale peaks.
    /// Only a user-selected boost (including its ramp down) needs a limiter.
    static func renderSample(_ sample: Float, gain: Float) -> Float {
        let scaled = sample * gain
        return gain > 1 ? softLimit(scaled) : scaled
    }

    /// Soft-knee limiter to avoid clipping above unity gain
    @inline(__always)
    private static func softLimit(_ sample: Float) -> Float {
        let threshold: Float = 0.8
        let ceiling: Float = 1.0

        let absSample = abs(sample)
        if absSample <= threshold {
            return sample
        }

        let overshoot = absSample - threshold
        let headroom = ceiling - threshold
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))

        return sample >= 0 ? compressed : -compressed
    }
}
