import AppKit
import Combine
import Darwin
import SwiftUI

/// AppKit owns the application lifecycle so a hidden SwiftUI scene cannot
/// terminate this menu-bar-only app on macOS 26.
@main
@MainActor
enum MacVolumeApp {
    static func main() {
        AudioProcessEnumerator.runCommandLineModeIfNeeded()

        // A mounted DMG and the installed copy share the same bundle ID.
        // Reuse the first running instance instead of creating competing
        // NSStatusItems that can hide one another in the menu bar.
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleIdentifier
           ).first(where: { $0.processIdentifier != currentProcessIdentifier }) {
            NSLog("MacVolume: 已有实例运行（PID=%d），当前实例退出", existing.processIdentifier)
            existing.activate(options: [.activateIgnoringOtherApps])
            Darwin.exit(0)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: AudioProcessManager?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Older SwiftUI MenuBarExtra builds stored a hidden scene item as
        // `Item-0`. Remove only that stale app-local preference before the
        // AppKit-owned item is created.
        UserDefaults.standard.removeObject(forKey: "NSStatusItem VisibleCC Item-0")

        let manager = AudioProcessManager()
        self.manager = manager

        configureStatusItem(using: manager)
        configurePopover(using: manager)

        manager.$masterMuted
            .removeDuplicates()
            .sink { [weak self] muted in
                self?.updateStatusIcon(muted: muted)
            }
            .store(in: &cancellables)

        NSLog("MacVolume: AppKit 菜单栏状态项已创建")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func configureStatusItem(using manager: AudioProcessManager) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MacVolumeStatusItem"
        item.isVisible = true

        guard let button = item.button else {
            NSLog("MacVolume: 无法创建菜单栏按钮")
            return
        }

        // Keep a short text fallback next to the SF Symbol. This makes the
        // item visibly occupy the menu bar even when a system symbol fails to
        // render on a particular macOS/SF Symbols combination.
        button.title = "MV"
        button.imagePosition = .imageLeft
        button.appearsDisabled = false
        button.isBordered = false
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        statusItem = item
        updateStatusIcon(muted: manager.masterMuted)

        NSLog("MacVolume: 状态项已强制显示，长度=%.1f，按钮标题=%@", item.length, button.title)
    }

    private func configurePopover(using manager: AudioProcessManager) {
        let content = MixerView()
            .environmentObject(manager)

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 560)
        popover.contentViewController = NSHostingController(rootView: content)
    }

    private func updateStatusIcon(muted: Bool) {
        let symbolName = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: muted ? "MacVolume 已静音" : "MacVolume"
        ) else { return }

        image.isTemplate = true
        guard let button = statusItem?.button else { return }
        button.image = image
        button.toolTip = "MacVolume"
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
