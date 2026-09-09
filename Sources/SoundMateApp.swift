import AppKit
import Darwin
import SwiftUI

/// AppKit entry point for the regular-window SoundMate app.
@main
@MainActor
enum SoundMateApp {
    static func main() {
        AudioProcessEnumerator.runCommandLineModeIfNeeded()

        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleID
           ).first(where: { $0.processIdentifier != currentPID }) {
            NSLog("SoundMate: 已有实例 PID=%d，当前实例退出", existing.processIdentifier)
            existing.activate(options: [.activateIgnoringOtherApps])
            Darwin.exit(0)
        }

        let application = NSApplication.shared
        let delegate = SoundMateAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
private final class SoundMateAppDelegate: NSObject, NSApplicationDelegate {
    private var manager: AudioProcessManager?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()

        let manager = AudioProcessManager()
        self.manager = manager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SoundMate"
        // Keep enough vertical room for the communication section and the
        // footer, while avoiding the oversized 820-point default window.
        window.minSize = NSSize(width: 420, height: 732)
        window.isReleasedWhenClosed = false
        // Bump the autosave key so the previous oversized V3 frame does not
        // keep being restored for existing installations.
        window.setFrameAutosaveName("SoundMateMainWindowV4")
        window.contentViewController = NSHostingController(
            rootView: MixerView().environmentObject(manager)
        )
        window.setContentSize(NSSize(width: 480, height: 700))
        window.center()

        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("SoundMate: 普通应用主窗口已创建")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindow?.contentViewController = nil
        mainWindow = nil
        manager = nil
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "SoundMate")
        appMenu.addItem(
            withTitle: "About SoundMate",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide SoundMate",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "隐藏其他应用",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit SoundMate",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "缩放",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "将所有窗口置于最前",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
