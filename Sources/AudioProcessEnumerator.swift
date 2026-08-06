import AudioToolbox
import Darwin
import Foundation

struct AudioProcessRecord: Sendable {
    let pid: pid_t
    let objectID: AudioObjectID
    let bundleIdentifier: String?
    let isOutputting: Bool
}

/// Runs Core Audio process queries in a short-lived helper mode.
/// Some macOS 26 HAL proxy objects can block a client process indefinitely;
/// isolating the query lets the main menu-bar app time it out safely.
enum AudioProcessEnumerator {
    static func runCommandLineModeIfNeeded() {
        guard CommandLine.arguments.contains("--enumerate-audio") else { return }

        let excluded = CommandLine.arguments.drop(while: { $0 != "--exclude" }).dropFirst().first
            .flatMap { pid_t($0) }
        var excludedPIDs: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
        if let excluded { excludedPIDs.insert(excluded) }
        let records = enumerate(excluding: excludedPIDs)
        for record in records {
            let bundleID = record.bundleIdentifier ?? ""
            print("\(record.pid),\(record.objectID),\(record.isOutputting ? 1 : 0),\(bundleID)")
        }
        fflush(stdout)
        exit(0)
    }

    static func enumerate(excluding excludedPIDs: Set<pid_t>) -> [AudioProcessRecord] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        ) == noErr else { return [] }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        var objectList = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &objectList
        ) == noErr else { return [] }

        return objectList.compactMap { objectID in
            guard let pid = readPID(objectID), !excludedPIDs.contains(pid) else { return nil }
            // The process object list is the source of truth for audio-capable
            // processes. Do not filter on a momentary running flag here: Edge,
            // WeChat and similar apps can move output to a newly-created Helper.
            // Keep the output state separately for diagnostics and future UI use.
            guard processExists(pid) else { return nil }
            let bundleIdentifier = readString(objectID, kAudioProcessPropertyBundleID)
            let isOutputting = readBool(objectID, kAudioProcessPropertyIsRunningOutput)
            return AudioProcessRecord(
                pid: pid,
                objectID: objectID,
                bundleIdentifier: bundleIdentifier,
                isOutputting: isOutputting
            )
        }
    }

    private static func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func readBool(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
