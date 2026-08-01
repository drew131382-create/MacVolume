import SwiftUI

@main
struct MacVolumeApp: App {
    @StateObject private var manager = AudioProcessManager()

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
