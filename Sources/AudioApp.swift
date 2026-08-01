import AppKit
import CoreAudio
import Foundation

/// Represents an application that is currently outputting audio
struct AudioApp: Identifiable, Equatable, Hashable {
    let id: pid_t
    let objectID: AudioObjectID
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    var volume: Float  // 0.0 - 1.5, 用户设定的音量
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
