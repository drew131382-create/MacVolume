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
private final class CleanAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let statusAutosaveName = "MacVolumeStatusItemV3"

    private var manager: AudioProcessManager?
    private var statusItem: NSStatusItem?
    private var testWindow: NSWindow?
    private let popover = NSPopover()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = AudioProcessManager()
        self.manager = manager

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.statusAutosaveName
        item.behavior = []
        statusItem = item

        guard let button = item.button else {
            NSLog("MacVolume Clean: 无法创建菜单栏按钮")
            return
        }

        button.title = ""
        button.image = statusIcon(muted: manager.masterMuted)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.toolTip = "MacVolume"
        button.setAccessibilityLabel("MacVolume")
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        updateStatusIcon(muted: manager.masterMuted)

        let content = MixerView().environmentObject(manager)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 640)
        popover.contentViewController = NSHostingController(rootView: content)

        manager.$masterMuted
            .removeDuplicates()
            .sink { [weak self] muted in
                self?.updateStatusIcon(muted: muted)
            }
            .store(in: &cancellables)

        NSLog("MacVolume Clean: 菜单栏音量状态项已创建，系统方形长度，可见=\(item.isVisible)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.recordStatusItemDiagnostic()
        }

        // Local UI smoke-test hooks. They are inert during a normal launch.
        if CommandLine.arguments.contains("--show-window") {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 640),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacVolume 菜单预览"
            window.contentViewController = NSHostingController(rootView: MixerView().environmentObject(manager))
            window.center()
            window.makeKeyAndOrderFront(nil)
            testWindow = window
        } else if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.togglePopover(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoringOutsideClicks()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopMonitoringOutsideClicks()
    }

    private func updateStatusIcon(muted: Bool) {
        guard let button = statusItem?.button else { return }

        button.title = ""
        button.image = statusIcon(muted: muted)
        button.imagePosition = .imageOnly
        button.toolTip = muted ? "MacVolume（已静音）" : "MacVolume"
    }

    private func statusIcon(muted: Bool) -> NSImage? {
        let symbolName = muted ? "speaker.slash" : "speaker.wave.2"
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: muted ? "MacVolume 已静音" : "MacVolume 音量"
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func recordStatusItemDiagnostic() {
        guard let item = statusItem else { return }

        var diagnostic: [String: Any] = [
            "isVisible": item.isVisible,
            "length": item.length,
            "hasButton": item.button != nil,
            "activationPolicy": NSApp.activationPolicy().rawValue,
        ]
        if let window = item.button?.window {
            diagnostic["windowVisible"] = window.isVisible
            diagnostic["windowFrame"] = NSStringFromRect(window.frame)
            diagnostic["screenFrame"] = window.screen.map { NSStringFromRect($0.frame) } ?? "nil"
        } else {
            diagnostic["windowVisible"] = false
            diagnostic["windowFrame"] = "nil"
            diagnostic["screenFrame"] = "nil"
        }
        diagnostic["usesFallbackPanel"] = false
        UserDefaults.standard.set(diagnostic, forKey: "MacVolume.StatusItemDiagnostic")
        NSLog("MacVolume Clean: 状态项诊断 \(diagnostic)")
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            alignPopoverWithMenuBar()
            DispatchQueue.main.async { [weak self] in
                self?.alignPopoverWithMenuBar()
            }
            startMonitoringOutsideClicks()
        }
    }

    private func alignPopoverWithMenuBar() {
        guard popover.isShown,
              let popoverWindow = popover.contentViewController?.view.window,
              let statusItemWindow = statusItem?.button?.window
        else { return }

        // AppKit can leave a visible gap below a Control Center-proxied status
        // item. Align the popover's top edge with the native status-item
        // window's bottom edge, using screen coordinates so this also works on
        // displays with different menu-bar heights.
        let verticalOffset = statusItemWindow.frame.minY - popoverWindow.frame.maxY
        guard abs(verticalOffset) > 0.5 else { return }

        var frame = popoverWindow.frame
        frame.origin.y += verticalOffset
        popoverWindow.setFrame(frame, display: true)
    }

    private func startMonitoringOutsideClicks() {
        stopMonitoringOutsideClicks()

        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownEvents) { [weak self] event in
            guard let self, self.popover.isShown else { return event }

            let popoverWindow = self.popover.contentViewController?.view.window
            let statusItemWindow = self.statusItem?.button?.window
            if event.window !== popoverWindow && event.window !== statusItemWindow {
                self.popover.performClose(nil)
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownEvents) { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }

            self?.popover.performClose(nil)
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
    }
}
