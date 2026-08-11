import CoreAudio
import Darwin
import Foundation

/// Protocol for audio tap management
protocol AudioTapManagerProtocol {
    func setVolume(for pid: pid_t, volume: Float)
    func setMute(for pid: pid_t, muted: Bool)
    func setDuckingCompensation(for pid: pid_t, gain: Float)
    func removeTap(for pid: pid_t)
    func removeUnusedTaps(keeping activePIDs: Set<pid_t>)
    func resetAudio()
}

/// Factory to create the appropriate tap manager based on OS version
class AudioTapManagerFactory {
    static func create() -> AudioTapManagerProtocol {
        if #available(macOS 14.2, *) {
            return AudioTapManager()
        } else {
            return AudioTapManagerFallback()
        }
    }
}

/// Audio tap manager using ProcessTapController for proper volume/mute control
@available(macOS 14.2, *)
class AudioTapManager: AudioTapManagerProtocol {

    private var activeTaps: [pid_t: ProcessTapController] = [:]
    private var tapStates: [pid_t: (volume: Float, muted: Bool)] = [:]
    /// Extra gain used only to counter voice-chat ducking. This is deliberately
    /// separate from tapStates so it never changes the user's saved app volume.
    private var duckingCompensationByPID: [pid_t: Float] = [:]
    private let queue = DispatchQueue(label: "com.macvolume.audiotap", qos: .userInteractive)

    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceChangePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        startDeviceChangeListener()
    }

    deinit {
        if let block = deviceChangeListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &deviceChangePropertyAddress,
                queue,
                block
            )
        }
        for (_, tap) in activeTaps {
            tap.invalidate()
        }
    }

    private func startDeviceChangeListener() {
        deviceChangeListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceChangePropertyAddress,
            queue,
            deviceChangeListenerBlock!
        )

        if status != noErr {
            NSLog("MacVolume: Failed to register device change listener: \(status)")
        }
    }

    private func handleDeviceChange() {
        NSLog("MacVolume: Output device changed - recreating taps")

        for (pid, tap) in activeTaps {
            tapStates[pid] = (volume: tap.volume, muted: tap.isMuted)
        }

        let pidsToRecreate = Array(activeTaps.keys)
        for (pid, tap) in activeTaps {
            tap.invalidate()
            NSLog("MacVolume: Invalidated tap for PID: \(pid)")
        }
        activeTaps.removeAll()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            self.queue.async {
                for pid in pidsToRecreate {
                    self.recreateTapWithRetry(pid: pid, attempt: 1, maxAttempts: 3)
                }
            }
        }
    }

    private func recreateTapWithRetry(pid: pid_t, attempt: Int, maxAttempts: Int) {
        guard let tap = ProcessTapController(pid: pid) else {
            if attempt < maxAttempts {
                let delay = Double(attempt) * 0.1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.queue.async {
                        self?.recreateTapWithRetry(pid: pid, attempt: attempt + 1, maxAttempts: maxAttempts)
                    }
                }
            } else {
                NSLog("MacVolume: Could not recreate tap for PID \(pid)")
            }
            return
        }

        do {
            try tap.activate()

            if let state = self.tapStates[pid] {
                tap.volume = state.volume
                tap.isMuted = state.muted
            }
            tap.duckingCompensationGain = self.duckingCompensationByPID[pid] ?? 1.0

            self.activeTaps[pid] = tap
        } catch {
            if attempt < maxAttempts {
                let delay = Double(attempt) * 0.1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.queue.async {
                        self?.recreateTapWithRetry(pid: pid, attempt: attempt + 1, maxAttempts: maxAttempts)
                    }
                }
            } else {
                NSLog("MacVolume: Failed to reactivate tap for PID \(pid): \(error.localizedDescription)")
            }
        }
    }

    func setVolume(for pid: pid_t, volume: Float) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if let existingTap = self.activeTaps[pid] {
                existingTap.volume = volume
                self.tapStates[pid] = (volume: volume, muted: existingTap.isMuted)
                self.removeTapIfIdle(for: pid)
            } else {
                if volume != 1.0 {
                    self.ensureTapExists(for: pid)
                    self.activeTaps[pid]?.volume = volume
                    self.tapStates[pid] = (volume: volume, muted: false)
                }
            }
        }
    }

    /// Applies a transient post-limiter gain to counter the attenuation caused
    /// by another app's voice-processing unit. The user-selected volume remains
    /// independent and is restored unchanged when the call ends.
    func setDuckingCompensation(for pid: pid_t, gain: Float) {
        queue.async { [weak self] in
            guard let self else { return }

            let clampedGain = max(1.0, min(8.0, gain))
            if clampedGain > 1.0 {
                self.duckingCompensationByPID[pid] = clampedGain
                self.ensureTapExists(for: pid)
                self.activeTaps[pid]?.duckingCompensationGain = clampedGain
            } else {
                self.duckingCompensationByPID.removeValue(forKey: pid)
                self.activeTaps[pid]?.duckingCompensationGain = 1.0
                self.removeTapIfIdle(for: pid)
            }
        }
    }

    func setMute(for pid: pid_t, muted: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if let existingTap = self.activeTaps[pid] {
                existingTap.isMuted = muted
                self.tapStates[pid] = (volume: existingTap.volume, muted: muted)
                self.removeTapIfIdle(for: pid)
            } else {
                if muted {
                    self.tapStates[pid] = (volume: 1.0, muted: true)
                    self.ensureTapExists(for: pid)
                    if let tap = self.activeTaps[pid] {
                        tap.isMuted = muted
                    }
                } else {
                    self.tapStates.removeValue(forKey: pid)
                }
            }
        }
    }

    func removeTap(for pid: pid_t) {
        queue.async { [weak self] in
            self?.duckingCompensationByPID.removeValue(forKey: pid)
            if let tap = self?.activeTaps.removeValue(forKey: pid) {
                tap.invalidate()
            }
            self?.tapStates.removeValue(forKey: pid)
        }
    }

    func removeUnusedTaps(keeping activePIDs: Set<pid_t>) {
        queue.async { [weak self] in
            guard let self else { return }

            self.duckingCompensationByPID = self.duckingCompensationByPID.filter {
                activePIDs.contains($0.key)
            }
            let staleStatePIDs = Set(self.tapStates.keys).subtracting(activePIDs)
            for pid in staleStatePIDs {
                self.tapStates.removeValue(forKey: pid)
            }

            let stalePIDs = Set(self.activeTaps.keys).subtracting(activePIDs)
            for pid in stalePIDs {
                if let tap = self.activeTaps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.tapStates.removeValue(forKey: pid)
                }
            }
        }
    }

    func resetAudio() {
        queue.async { [weak self] in
            guard let self else { return }

            for (pid, tap) in self.activeTaps {
                self.tapStates[pid] = (volume: tap.volume, muted: tap.isMuted)
                tap.invalidate()
            }

            let pidsToRecreate = self.tapStates.keys.filter { self.isProcessRunning($0) }
            self.activeTaps.removeAll()

            for pid in pidsToRecreate {
                self.recreateTapWithRetry(pid: pid, attempt: 1, maxAttempts: 3)
            }
        }
    }

    private func removeTapIfIdle(for pid: pid_t) {
        guard duckingCompensationByPID[pid] == nil else { return }
        guard let tap = activeTaps[pid], tap.volume == 1.0, !tap.isMuted else { return }
        activeTaps.removeValue(forKey: pid)
        tapStates.removeValue(forKey: pid)
        tap.invalidate()
    }

    // MARK: - Private Implementation

    private func ensureTapExists(for pid: pid_t) {
        guard activeTaps[pid] == nil else { return }

        guard let tap = ProcessTapController(pid: pid) else {
            NSLog("MacVolume: Could not create ProcessTapController for PID \(pid)")
            return
        }

        do {
            try tap.activate()
            tap.duckingCompensationGain = duckingCompensationByPID[pid] ?? 1.0
            activeTaps[pid] = tap
        } catch {
            NSLog("MacVolume: Failed to activate tap for PID \(pid): \(error.localizedDescription)")
        }
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Fallback for older macOS

class AudioTapManagerFallback: AudioTapManagerProtocol {
    func setVolume(for pid: pid_t, volume: Float) {
        NSLog("MacVolume: Volume control not available on this macOS version")
    }
    func setMute(for pid: pid_t, muted: Bool) {
        NSLog("MacVolume: Mute control not available on this macOS version")
    }
    func setDuckingCompensation(for pid: pid_t, gain: Float) {
        NSLog("MacVolume: Ducking compensation not available on this macOS version")
    }
    func removeTap(for pid: pid_t) {}
    func removeUnusedTaps(keeping activePIDs: Set<pid_t>) {}
    func resetAudio() {}

    init() {
        NSLog("MacVolume: AudioTap requires macOS 14.2+")
    }
}
