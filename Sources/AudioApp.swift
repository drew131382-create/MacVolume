import AppKit
import CoreAudio
import Foundation

/// Represents an application with a current Core Audio process object.
/// The process may be temporarily silent while an app switches tabs or Helpers.
struct AudioApp: Identifiable, Equatable, Hashable {
    let id: pid_t
    let objectID: AudioObjectID
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let isOutputting: Bool
    var volume: Float  // 0.0 - 3.0, 1.0 = 100%（滑块中点）
    var isMuted: Bool
    var additionalPids: Set<pid_t> = []

    var allPids: Set<pid_t> {
        var pids = additionalPids
        pids.insert(id)
        return pids
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
