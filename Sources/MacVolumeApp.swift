import SwiftUI

@main
struct MacVolumeApp: App {
    @StateObject private var manager: AudioProcessManager

    init() {
        AudioProcessEnumerator.runCommandLineModeIfNeeded()
        _manager = StateObject(wrappedValue: AudioProcessManager())
    }

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(manager)
        } label: {
            Image(systemName: manager.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
