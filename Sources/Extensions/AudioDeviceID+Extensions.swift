import AudioToolbox
import Foundation

extension AudioObjectID {
    static let unknown: AudioObjectID = kAudioObjectUnknown

    var isValid: Bool {
        self != kAudioObjectUnknown && self != 0
    }

    /// Wait until an aggregate device is ready for I/O operations.
    /// Returns true if device is ready, false if timeout.
    func waitUntilReady(timeout: TimeInterval) -> Bool {
        let startTime = CFAbsoluteTimeGetCurrent()

        while CFAbsoluteTimeGetCurrent() - startTime < timeout {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )

            var propertySize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(
                self,
                &propertyAddress,
                0,
                nil,
                &propertySize
            )

            if status == noErr && propertySize > 0 {
                return true
            }

            Thread.sleep(forTimeInterval: 0.01)
        }

        return false
    }

    /// Read the nominal sample rate of the device
    func readNominalSampleRate() throws -> Float64 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Float64 = 0
        var propertySize = UInt32(MemoryLayout<Float64>.size)

        let status = AudioObjectGetPropertyData(
            self,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &sampleRate
        )

        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        return sampleRate
    }
}

// MARK: - PID Translation

extension AudioObjectID {
    /// Translate a PID to a Process AudioObjectID
    static func translatePIDToProcessObject(pid: pid_t) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var inputPID = pid
        var processObjectID = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &size,
            &processObjectID
        )

        return status == noErr && processObjectID != 0 ? processObjectID : nil
    }
}
