import AppKit
import Combine
import Darwin
import SwiftUI

/// Clean AppKit entry point for the rebuilt menu-bar application.
@main
@MainActor
enum CleanMacVolumeApp {
    static func main() {
        AudioProcessEnumerator.runCommandLineModeIfNeeded()

        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleID
           ).first(where: { $0.processIdentifier != currentPID }) {
            NSLog("MacVolume Clean: 已有实例 PID=%d，当前实例退出", existing.processIdentifier)
            existing.activate(options: [.activateIgnoringOtherApps])
            Darwin.exit(0)
        }

        let application = NSApplication.shared
        let delegate = CleanAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class CleanAppDelegate: NSObject, NSApplicationDelegate {
    private var manager: AudioProcessManager?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = AudioProcessManager()
        self.manager = manager

        let item = NSStatusBar.system.statusItem(withLength: 34)
        item.autosaveName = "MacVolumeCleanStatusItem"
        item.isVisible = true
        statusItem = item

        guard let button = item.button else {
            NSLog("MacVolume Clean: 无法创建菜单栏按钮")
            return
        }

        // Text is intentional: it cannot disappear because of SF Symbol
        // rendering or template-image tinting differences between macOS builds.
        button.title = "MV"
        button.image = nil
        button.alignment = .center
        button.font = NSFont.menuBarFont(ofSize: 0)
        button.isBordered = false
        button.appearsDisabled = false
        button.toolTip = "MacVolume"
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])

        let content = MixerView().environmentObject(manager)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 560)
        popover.contentViewController = NSHostingController(rootView: content)

        manager.$masterMuted
            .removeDuplicates()
            .sink { [weak self] muted in
                self?.updateTitle(muted: muted)
            }
            .store(in: &cancellables)

        NSLog("MacVolume Clean: 菜单栏状态项已创建，标题=MV，长度=34")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func updateTitle(muted: Bool) {
        statusItem?.button?.title = muted ? "M!" : "MV"
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
