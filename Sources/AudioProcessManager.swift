import AppKit
import Combine
import CoreAudio
import Darwin
import Foundation

/// Manages detection and tracking of applications that are outputting audio
@MainActor
class AudioProcessManager: ObservableObject {
    @Published var audioApps: [AudioApp] = []
    @Published var masterVolume: Float = 1.0
    @Published var masterMuted: Bool = false
    @Published var permissionGranted: Bool = true

    private let deviceVolume = DeviceVolume()
    private var tapManager: AudioTapManagerProtocol?
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let volumeState = VolumeState()
    /// 当前拥有 CoreAudio 进程对象（正在发声）的 PID 集合
    private var audioPIDs: Set<pid_t> = []
    private var didLogInitialApps = false

    /// 系统级进程默认隐藏
    private let defaultHiddenApps: Set<String> = [
        "com.apple.universalaccessd",
        "com.apple.SiriNCService",
        "com.apple.accessibility.AccessibilityUIServer",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.SystemUIServer",
        "com.apple.coreservices.uiagent",
        "com.apple.AmbientDisplayAgent",
        "com.apple.mediaremoted",
        "com.apple.audio.coreaudiod",
        "coreaudiod",
        "com.apple.hidd",
        "com.apple.corespeech",
        "com.apple.systemsound",
        "loginwindow",
        "PowerChime",
        "MacVolume",
    ]

    private static let systemDaemonPrefixes: [String] = [
        "com.apple.siri",
        "com.apple.assistant",
        "com.apple.audio",
        "com.apple.coreaudio",
        "com.apple.mediaremote",
        "com.apple.accessibility.heard",
        "com.apple.hearingd",
        "com.apple.voicebankingd",
    ]

    private static let systemDaemonNames: [String] = [
        "systemsoundserverd",
        "coreaudiod",
        "audiomxd",
        "historicalaudiod",
    ]

    init() {
        permissionGranted = AudioPermissionHelper.checkPermission()
        NSLog("MacVolume: 启动，音频权限=\(permissionGranted)")
        tapManager = AudioTapManagerFactory.create()
        deviceVolume.onStateChange = { [weak self] in
            self?.syncMasterFromDevice()
        }
        deviceVolume.start()
        syncMasterFromDevice()
        startMonitoring()
        AudioPermissionHelper.requestPermission { [weak self] granted in
            NSLog("MacVolume: 权限请求结果 granted=\(granted)")
            self?.permissionGranted = granted
        }
    }

    /// 把系统输出设备的音量/静音同步到界面
    private func syncMasterFromDevice() {
        masterVolume = deviceVolume.volume
        masterMuted = deviceVolume.isMuted
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        Task {
            await updateAudioApps()
        }

        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateAudioApps()
            }
        }

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.updateAudioApps()
                }
            }
            .store(in: &cancellables)

        // 面板打开（成为 key window）时立即刷新，避免等 2 秒轮询
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.updateAudioApps()
                }
            }
            .store(in: &cancellables)
    }

    /// 更新应用列表：仅显示当前正在发声（拥有音频进程对象）的应用
    func updateAudioApps() async {
        let processIDs = await getAudioProcessIDs()
        let runningApps = NSWorkspace.shared.runningApplications
        let myPID = ProcessInfo.processInfo.processIdentifier

        var audioObjectByPID: [pid_t: AudioObjectID] = [:]

        for objectID in processIDs {
            guard objectID.readProcessIsRunning() else { continue }
            guard let pid = try? objectID.readProcessPID(), pid != myPID else { continue }
            audioObjectByPID[pid] = objectID
        }
        audioPIDs = Set(audioObjectByPID.keys)

        // 把发声的 PID 映射到其宿主主应用，并做 Helper 合并
        var appGroups: [String: (app: NSRunningApplication?, objectID: AudioObjectID, pids: Set<pid_t>)] = [:]

        for (pid, objectID) in audioObjectByPID {
            let directApp = runningApps.first { $0.processIdentifier == pid }
            let isRealApp = directApp?.bundleURL?.pathExtension == "app"
            var resolvedApp = isRealApp ? directApp : findResponsibleApp(for: pid, in: runningApps)

            let bundleID = resolvedApp?.bundleIdentifier ?? objectID.readProcessBundleID()
            let localizedName = resolvedApp?.localizedName ?? ""
            var name: String
            if !localizedName.isEmpty {
                name = localizedName
            } else {
                let bundleFallback = objectID.readProcessBundleID()?.components(separatedBy: ".").last ?? ""
                name = bundleFallback.isEmpty ? (processName(for: pid) ?? "Unknown") : bundleFallback
            }

            if isSystemDaemon(bundleID: bundleID, name: name) { continue }

            var groupKey = bundleID ?? name

            // WebKit / Safari 相关进程统一归入 Safari
            if let bid = bundleID, bid == "com.apple.WebKit.GPU" || bid == "com.apple.WebKit.WebContent" || bid == "com.apple.WebKit.Networking" {
                if let safari = runningApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
                    resolvedApp = safari
                    groupKey = safari.bundleIdentifier!
                    if let safariName = safari.localizedName {
                        name = safariName
                    }
                }
            }

            // 通用 Helper / GPU / Service：从 bundleID 去掉最后一段匹配宿主
            if name == "GPU" || name.contains("Helper") || name.contains("Service") {
                if let bid = bundleID {
                    let parts = bid.components(separatedBy: ".")
                    if parts.count > 2 {
                        let potentialParentID = parts.dropLast().joined(separator: ".")
                        if let parent = runningApps.first(where: { $0.bundleIdentifier == potentialParentID }) {
                            resolvedApp = parent
                            groupKey = potentialParentID
                        }
                    }
                }
            }

            if var existing = appGroups[groupKey] {
                existing.pids.insert(pid)
                appGroups[groupKey] = (existing.app ?? resolvedApp, existing.objectID, existing.pids)
            } else {
                appGroups[groupKey] = (resolvedApp, objectID, [pid])
            }
        }

        var newApps: [AudioApp] = []

        for (groupKey, group) in appGroups {
            let app = group.app
            let allPids = group.pids
            let mainObjectID = group.objectID

            let mainPid = (app?.processIdentifier ?? -1) != -1 ? app!.processIdentifier : allPids.first!

            let volume = volumeState.loadSavedVolume(for: mainPid, identifier: groupKey) ?? 1.0
            let muted = volumeState.loadSavedMute(for: mainPid, identifier: groupKey) ?? false

            let additional = allPids.subtracting([mainPid])

            let finalName: String
            if let ln = app?.localizedName, !ln.isEmpty {
                finalName = ln
            } else {
                let bundleFallback = mainObjectID.readProcessBundleID()?.components(separatedBy: ".").last ?? ""
                finalName = bundleFallback.isEmpty ? (processName(for: mainPid) ?? "Unknown App") : bundleFallback
            }
            let finalIcon = app?.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)

            let audioApp = AudioApp(
                id: mainPid,
                objectID: mainObjectID,
                name: finalName,
                bundleIdentifier: groupKey,
                icon: finalIcon,
                volume: volume,
                isMuted: muted,
                additionalPids: additional
            )

            newApps.append(audioApp)
        }

        newApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if !didLogInitialApps {
            let visible = newApps.filter { !isAppHidden($0) }
            NSLog("MacVolume: 显示 \(visible.count)/\(newApps.count) 个应用: \(visible.map(\.name).joined(separator: ", "))")
            didLogInitialApps = true
        }

        let activePIDs = Set(newApps.flatMap(\.allPids))
        tapManager?.removeUnusedTaps(keeping: activePIDs)

        self.audioApps = newApps

        for app in newApps {
            applyEffectiveState(to: app)
        }
    }

    /// 找到一个进程的宿主主应用（用于 Helper / 子进程）
    private func findResponsibleApp(for pid: pid_t, in runningApps: [NSRunningApplication]) -> NSRunningApplication? {
        guard let app = runningApps.first(where: { $0.processIdentifier == pid })
            ?? NSRunningApplication(processIdentifier: pid) else { return nil }
        return parentApp(for: app, in: runningApps) ?? app
    }

    /// 用可执行文件路径取进程名（无 bundle 的进程，如 daemon / CLI）
    private func processName(for pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        let size = proc_pidpath(pid, &path, 4096)
        guard size > 0 else { return nil }
        let fullPath = String(cString: path)
        return URL(fileURLWithPath: fullPath).lastPathComponent
    }

    // MARK: - Master Controls

    /// 主音量与系统输出设备音量双向同步：拖动滑块即设置设备音量
    func setMasterVolume(_ volume: Float) {
        deviceVolume.setVolume(volume)
    }

    func toggleMasterMute() {
        deviceVolume.setMuted(!deviceVolume.isMuted)
    }

    /// 每个 App 的音量是占比（0-1）：最终响度 = 设备音量 × App 占比
    private func applyEffectiveState(to app: AudioApp) {
        for pid in app.allPids where audioPIDs.contains(pid) {
            tapManager?.setVolume(for: pid, volume: app.volume)
            tapManager?.setMute(for: pid, muted: app.isMuted)
        }
    }

    // MARK: - Per-App Controls

    func setVolume(for app: AudioApp, volume: Float) {
        guard let index = audioApps.firstIndex(where: { $0.id == app.id }) else { return }

        let clamped = max(0, min(1.0, volume))
        audioApps[index].volume = clamped

        let identifier = app.bundleIdentifier ?? app.name
        volumeState.setVolume(for: app.id, to: clamped, identifier: identifier)

        applyEffectiveState(to: audioApps[index])
    }

    /// 双击音量按钮：将当前 App 音量复位为 100%
    func resetVolume(for app: AudioApp) {
        guard let index = audioApps.firstIndex(where: { $0.id == app.id }) else { return }

        audioApps[index].volume = 1.0

        let identifier = app.bundleIdentifier ?? app.name
        volumeState.setVolume(for: app.id, to: 1.0, identifier: identifier)

        applyEffectiveState(to: audioApps[index])
    }

    func toggleMute(for app: AudioApp) {
        guard let index = audioApps.firstIndex(where: { $0.id == app.id }) else { return }

        audioApps[index].isMuted.toggle()
        let isMuted = audioApps[index].isMuted

        let identifier = app.bundleIdentifier ?? app.name
        volumeState.setMute(for: app.id, to: isMuted, identifier: identifier)

        for pid in app.allPids where audioPIDs.contains(pid) {
            tapManager?.setMute(for: pid, muted: isMuted)
        }
    }

    /// Recreate active taps when audio starts glitching or output state gets stuck.
    func resetAudio() {
        tapManager?.resetAudio()
    }

    // MARK: - Visibility

    var visibleApps: [AudioApp] {
        audioApps.filter { !isAppHidden($0) }
    }

    private func isAppHidden(_ app: AudioApp) -> Bool {
        let identifier = app.bundleIdentifier ?? app.name
        if let bundleID = app.bundleIdentifier, defaultHiddenApps.contains(bundleID) {
            return true
        }
        if defaultHiddenApps.contains(app.name) {
            return true
        }
        if defaultHiddenApps.contains(identifier) {
            return true
        }
        return false
    }

    // MARK: - Private Helper Methods

    private func getAudioProcessIDs() async -> [AudioObjectID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else { return [] }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        var objectList = [AudioObjectID](repeating: 0, count: count)

        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &objectList
        )

        guard dataStatus == noErr else { return [] }

        return objectList
    }

    /// 判断一个应用是否为 Helper 子进程，并找到其宿主主应用
    private func parentApp(for app: NSRunningApplication, in runningApps: [NSRunningApplication]) -> NSRunningApplication? {
        let name = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""

        // 0. bundleID 前缀包含：子 bundle 归入父应用（如 com.tencent.xinWeChat.WeChatAppEx → com.tencent.xinWeChat）
        if !bundleID.isEmpty {
            for other in runningApps where other.processIdentifier != app.processIdentifier {
                if let otherBundle = other.bundleIdentifier, !otherBundle.isEmpty, bundleID.hasPrefix(otherBundle + ".") {
                    return other
                }
            }
        }

        let isHelper = name.contains("Helper")
            || name.contains("GPU")
            || name.contains("Service")
            || name == "Web Content"
            || bundleID.contains(".Helper")
            || bundleID.contains(".WebContent")
            || bundleID.contains(".GPU")
            || bundleID.contains(".Networking")
        guard isHelper else { return nil }

        // 1. 从 bundleID 去掉最后一段匹配宿主（com.xxx.YY.Helper → com.xxx.YY）
        if !bundleID.isEmpty {
            let parts = bundleID.components(separatedBy: ".")
            if parts.count > 2 {
                let candidate = parts.dropLast().joined(separator: ".")
                if let parent = runningApps.first(where: { $0.processIdentifier != app.processIdentifier && $0.bundleIdentifier == candidate }) {
                    return parent
                }
            }
        }

        // 2. 按名称前缀匹配宿主（如 "哔哩哔哩 Helper" → "哔哩哔哩"）
        for other in runningApps where other.processIdentifier != app.processIdentifier {
            let otherName = other.localizedName ?? ""
            if !otherName.isEmpty, name.hasPrefix(otherName) { return other }
            let otherBundle = other.bundleIdentifier ?? ""
            if !otherBundle.isEmpty, bundleID.hasPrefix(otherBundle) { return other }
        }

        // 3. WebKit 相关进程 → Safari
        if bundleID.hasPrefix("com.apple.WebKit") {
            return runningApps.first { $0.bundleIdentifier == "com.apple.Safari" }
        }

        return nil
    }

    private func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        if let bundleID {
            if Self.systemDaemonPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
        }
        let lowercaseName = name.lowercased()
        if Self.systemDaemonNames.contains(where: { lowercaseName.hasPrefix($0) }) {
            return true
        }
        return false
    }
}
