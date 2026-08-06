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

    private let deviceVolume = DeviceVolume()
    private var tapManager: AudioTapManagerProtocol?
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let volumeState = VolumeState()
    private var isUpdatingAudioApps = false
    /// 当前存在 Core Audio 进程对象的 PID 集合。
    /// 这比瞬时的“正在输出”集合稳定，适合绑定 Edge/微信的动态 Helper。
    private var audioPIDs: Set<pid_t> = []
    private var outputAudioPIDs: Set<pid_t> = []
    private var lastLoggedAudioSignature: String?

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
        NSLog("MacVolume: 启动，PID=\(ProcessInfo.processInfo.processIdentifier)")
        tapManager = AudioTapManagerFactory.create()
        deviceVolume.onStateChange = { [weak self] in
            self?.syncMasterFromDevice()
        }
        deviceVolume.start()
        syncMasterFromDevice()
        startMonitoring()
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

    /// 更新应用列表：显示当前存在 Core Audio 进程对象的应用。
    /// 是否正在输出单独记录，不用瞬时状态决定应用是否从列表消失。
    func updateAudioApps() async {
        guard !isUpdatingAudioApps else { return }
        isUpdatingAudioApps = true
        defer { isUpdatingAudioApps = false }

        // Core Audio 的进程属性查询在 macOS 26 上偶尔会阻塞，不能放在主线程。
        let myPID = ProcessInfo.processInfo.processIdentifier
        let queryResult = await Task.detached(priority: .userInitiated) {
            Self.getAudioProcessesUsingHelper(excluding: myPID)
        }.value
        guard let activeProcesses = queryResult else {
            // Core Audio 查询失败或超时时保留现有列表，不要误清空界面。
            return
        }
        let runningApps = NSWorkspace.shared.runningApplications

        var processByPID: [pid_t: AudioProcessRecord] = [:]

        for process in activeProcesses {
            processByPID[process.pid] = process
        }
        let currentAudioPIDs = Set(processByPID.keys)
        let newAudioPIDs = currentAudioPIDs.subtracting(audioPIDs)
        let removedAudioPIDs = audioPIDs.subtracting(currentAudioPIDs)
        audioPIDs = currentAudioPIDs
        outputAudioPIDs = Set(activeProcesses.filter(\.isOutputting).map(\.pid))

        let processSignature = activeProcesses
            .sorted { $0.pid < $1.pid }
            .map { "\($0.pid):\($0.objectID):\($0.isOutputting ? 1 : 0)" }
            .joined(separator: ";")
        let snapshotChanged = processSignature != lastLoggedAudioSignature
        if snapshotChanged {
            NSLog("MacVolume: Core Audio 进程快照 \(activeProcesses.count) 个，正在输出 \(outputAudioPIDs.count) 个，新加入 \(newAudioPIDs.count) 个，移除 \(removedAudioPIDs.count) 个")
            lastLoggedAudioSignature = processSignature
        }

        // 把 Core Audio PID 映射到其宿主主应用，并做 Helper 合并。
        var appGroups: [String: (app: NSRunningApplication?, objectID: AudioObjectID, pids: Set<pid_t>, outputPIDs: Set<pid_t>)] = [:]

        for (pid, process) in processByPID {
            let objectID = process.objectID
            let directApp = runningApps.first { $0.processIdentifier == pid }
            // Always try parent resolution. NSRunningApplication may expose a
            // Helper bundle as an .app itself, which previously bypassed this step.
            var resolvedApp = findResponsibleApp(for: pid, in: runningApps) ?? directApp

            let bundleID = resolvedApp?.bundleIdentifier ?? process.bundleIdentifier ?? objectID.readProcessBundleID()
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

            // 通用 Helper / GPU / Service：从 bundleID 逐段去掉后缀匹配宿主（大小写不敏感）
            let lowerName = name.lowercased()
            let isHelperName = lowerName == "gpu"
                || lowerName.contains("helper")
                || lowerName.contains("service")
                || lowerName.contains("webcontent")
                || lowerName.contains("networking")
            let isHelperBundle = bundleID?.lowercased().contains(".helper") == true
                || bundleID?.lowercased().contains(".gpu") == true
                || bundleID?.lowercased().contains(".service") == true
                || bundleID?.lowercased().contains(".webcontent") == true
                || bundleID?.lowercased().contains(".networking") == true

            if isHelperName || isHelperBundle {
                if let bid = bundleID {
                    var parts = bid.components(separatedBy: ".")
                    while parts.count > 1 {
                        parts.removeLast()
                        let candidate = parts.joined(separator: ".")
                        if let parent = runningApps.first(where: { $0.bundleIdentifier == candidate }) {
                            resolvedApp = parent
                            groupKey = candidate
                            break
                        }
                    }
                }
            }

            if var existing = appGroups[groupKey] {
                existing.pids.insert(pid)
                if process.isOutputting {
                    existing.outputPIDs.insert(pid)
                }
                appGroups[groupKey] = (existing.app ?? resolvedApp, existing.objectID, existing.pids, existing.outputPIDs)
            } else {
                appGroups[groupKey] = (
                    resolvedApp,
                    objectID,
                    [pid],
                    process.isOutputting ? [pid] : []
                )
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
                let bundleFallback = groupKey.components(separatedBy: ".").last ?? ""
                finalName = bundleFallback.isEmpty ? (processName(for: mainPid) ?? "Unknown App") : bundleFallback
            }
            let finalIcon = app?.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)

            let audioApp = AudioApp(
                id: mainPid,
                objectID: mainObjectID,
                name: finalName,
                bundleIdentifier: groupKey,
                icon: finalIcon,
                isOutputting: !group.outputPIDs.isEmpty,
                volume: volume,
                isMuted: muted,
                additionalPids: additional
            )

            newApps.append(audioApp)
        }

        newApps.sort(by: Self.appSort)

        if snapshotChanged {
            let groupDescriptions = appGroups
                .map { key, group in
                    let name = group.app?.localizedName ?? key
                    let pids = group.pids.sorted().map(String.init).joined(separator: ",")
                    let outputPIDs = group.outputPIDs.sorted().map(String.init).joined(separator: ",")
                    return "\(name)[\(pids)] 输出=[\(outputPIDs)]"
                }
                .sorted()
                .joined(separator: "; ")
            NSLog("MacVolume: 应用归并结果 \(newApps.count) 个: \(groupDescriptions)")
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

        let clamped = max(0, min(2.0, volume))
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
        audioApps
            .filter { !isAppHidden($0) }
            .sorted(by: Self.appSort)
    }

    /// 正在输出的应用置顶；同一状态下按名称、Bundle ID、主 PID 稳定排序。
    private static func appSort(_ lhs: AudioApp, _ rhs: AudioApp) -> Bool {
        if lhs.isOutputting != rhs.isOutputting {
            return lhs.isOutputting && !rhs.isOutputting
        }

        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }

        let lhsBundle = lhs.bundleIdentifier ?? ""
        let rhsBundle = rhs.bundleIdentifier ?? ""
        let bundleOrder = lhsBundle.localizedCaseInsensitiveCompare(rhsBundle)
        if bundleOrder != .orderedSame {
            return bundleOrder == .orderedAscending
        }

        return lhs.id < rhs.id
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

    private nonisolated static func getAudioProcessesUsingHelper(excluding excludedPID: pid_t) -> [AudioProcessRecord]? {
        guard let executableURL = Bundle.main.executableURL else {
            NSLog("MacVolume: 无法找到自身可执行文件，不能枚举 Core Audio 进程")
            return nil
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--enumerate-audio", "--exclude", String(excludedPID)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("MacVolume: 启动 Core Audio 枚举 Helper 失败: \(error.localizedDescription)")
            return nil
        }

        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard !process.isRunning else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            NSLog("MacVolume: Core Audio 枚举 Helper 超时，已终止子进程")
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            NSLog("MacVolume: Core Audio 枚举 Helper 退出异常，状态码=\(process.terminationStatus)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            NSLog("MacVolume: Core Audio 枚举 Helper 输出不是 UTF-8")
            return nil
        }

        var invalidLineCount = 0
        let records = text.split(separator: "\n").compactMap { line -> AudioProcessRecord? in
            let fields = line.split(separator: ",")
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]),
                  let objectID = AudioObjectID(fields[1]),
                  let outputFlag = Int(fields[2]) else {
                invalidLineCount += 1
                return nil
            }
            let bundleIdentifier = fields.count >= 4 && !fields[3].isEmpty
                ? String(fields[3])
                : nil
            return AudioProcessRecord(
                pid: pid,
                objectID: objectID,
                bundleIdentifier: bundleIdentifier,
                isOutputting: outputFlag != 0
            )
        }
        if invalidLineCount > 0 {
            NSLog("MacVolume: Core Audio 枚举 Helper 丢弃 \(invalidLineCount) 条格式错误记录")
        }
        return records
    }

    /// 判断一个应用是否为 Helper 子进程，并找到其宿主主应用
    private func parentApp(for app: NSRunningApplication, in runningApps: [NSRunningApplication]) -> NSRunningApplication? {
        let name = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""

        // 0. Bundle 路径包含关系：嵌套在主 App 包内的 Helper 归入最近的宿主。
        // 这覆盖 Edge Helper，也覆盖微信的 com.tencent.flue.WeChatAppEx
        // 这类 bundle ID 不共享前缀的辅助进程。
        if let appURL = app.bundleURL {
            let appPath = appURL.standardizedFileURL.path
            let pathCandidates = runningApps.compactMap { other -> (NSRunningApplication, Int)? in
                guard other.processIdentifier != app.processIdentifier,
                      let otherURL = other.bundleURL else { return nil }
                let otherPath = otherURL.standardizedFileURL.path
                guard appPath.hasPrefix(otherPath + "/") else { return nil }
                return (other, otherPath.count)
            }
            if let nearest = pathCandidates.max(by: { $0.1 < $1.1 })?.0 {
                return nearest
            }
        }

        // 1. bundleID 前缀包含：子 bundle 归入父应用（如 com.tencent.xinWeChat.WeChatAppEx → com.tencent.xinWeChat）
        if !bundleID.isEmpty {
            for other in runningApps where other.processIdentifier != app.processIdentifier {
                if let otherBundle = other.bundleIdentifier, !otherBundle.isEmpty, bundleID.hasPrefix(otherBundle + ".") {
                    return other
                }
            }
        }

        let lowerName = name.lowercased()
        let lowerBundle = bundleID.lowercased()
        let isHelper = lowerName.contains("helper")
            || lowerName.contains("gpu")
            || lowerName.contains("service")
            || lowerName == "web content"
            || lowerBundle.contains(".helper")
            || lowerBundle.contains(".webcontent")
            || lowerBundle.contains(".gpu")
            || lowerBundle.contains(".networking")
        guard isHelper else { return nil }

        // 2. 从 bundleID 逐段去掉后缀匹配宿主（com.xxx.YY.Helper → com.xxx.YY）
        if !bundleID.isEmpty {
            var parts = bundleID.components(separatedBy: ".")
            while parts.count > 1 {
                parts.removeLast()
                let candidate = parts.joined(separator: ".")
                if let parent = runningApps.first(where: { $0.processIdentifier != app.processIdentifier && $0.bundleIdentifier == candidate }) {
                    return parent
                }
            }
        }

        // 3. 按名称前缀匹配宿主（如 "哔哩哔哩 Helper" → "哔哩哔哩"）
        for other in runningApps where other.processIdentifier != app.processIdentifier {
            let otherName = other.localizedName ?? ""
            if !otherName.isEmpty, name.hasPrefix(otherName) { return other }
            let otherBundle = other.bundleIdentifier ?? ""
            if !otherBundle.isEmpty, bundleID.hasPrefix(otherBundle) { return other }
        }

        // 4. WebKit 相关进程 → Safari
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
