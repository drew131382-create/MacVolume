import CoreAudio
import Foundation

/// 监听并控制系统默认输出设备的音量与静音，实现与设备音量双向同步。
/// 主音量不再由 App 内部保存，而是以系统输出设备的实际音量为准。
@MainActor
final class DeviceVolume {
    /// 设备音量变化时回调（主线程）
    var onStateChange: (() -> Void)?

    private(set) var volume: Float = 1.0
    private(set) var isMuted: Bool = false

    private var deviceID: AudioObjectID = .unknown
    private let queue = DispatchQueue(label: "com.local.macvolume.devicevolume")
    private var systemListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    // MARK: - Lifecycle

    func start() {
        registerSystemListeners()
        refresh()
    }

    func stop() {
        for (id, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
        }
        for (id, addr, block) in systemListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
        }
        deviceListeners.removeAll()
        systemListeners.removeAll()
        deviceID = .unknown
    }

    // MARK: - Control

    func setVolume(_ value: Float) {
        guard deviceID != .unknown else { return }
        let v = max(0, min(1, value))
        for element in volumeElements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var scalar = v
            if AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr {
                volume = v
            } else {
                NSLog("MacVolume: 设置设备音量失败 element=\(element)")
            }
        }
        onStateChange?()
    }

    func setMuted(_ muted: Bool) {
        guard deviceID != .unknown else { return }
        for element in volumeElements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                isMuted = muted
            } else {
                NSLog("MacVolume: 设置设备静音失败 element=\(element)")
            }
        }
        onStateChange?()
    }

    // MARK: - Listeners

    private func registerSystemListeners() {
        let systemID = AudioObjectID(kAudioObjectSystemObject)

        var defaultAddr = defaultOutputAddress
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(systemID, &defaultAddr, queue, defaultBlock) == noErr {
            systemListeners.append((systemID, defaultAddr, defaultBlock))
        }

        var devicesAddr = devicesAddress
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(systemID, &devicesAddr, queue, devicesBlock) == noErr {
            systemListeners.append((systemID, devicesAddr, devicesBlock))
        }
    }

    private func registerDeviceListeners() {
        guard deviceID != .unknown else { return }

        for element in volumeElements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.readState() }
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block) == noErr {
                deviceListeners.append((deviceID, addr, block))
            }

            var mAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            let mBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.readState() }
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &mAddr, queue, mBlock) == noErr {
                deviceListeners.append((deviceID, mAddr, mBlock))
            }
        }
    }

    private func unregisterDeviceListeners() {
        for (id, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
        }
        deviceListeners.removeAll()
    }

    // MARK: - State

    private func refresh() {
        let newDeviceID = defaultOutputDeviceID()
        if newDeviceID != deviceID {
            unregisterDeviceListeners()
            deviceID = newDeviceID
            registerDeviceListeners()
        }
        readState()
    }

    private func readState() {
        guard deviceID != .unknown else { return }

        var sum: Float = 0
        var count: Float = 0
        var mutedValue: UInt32 = 0
        var mutedRead = false

        for element in volumeElements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var v: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &v) == noErr {
                sum += v
                count += 1
            }

            var mAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var m: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &mAddr, 0, nil, &size, &m) == noErr {
                mutedValue = m
                mutedRead = true
            }
        }

        if count > 0 {
            volume = max(0, min(1, sum / count))
        }
        if mutedRead {
            isMuted = mutedValue != 0
        }

        onStateChange?()
    }

    // MARK: - Addresses

    private var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 音量/静音作用的目标声道（立体声写两个声道，单声道只写 0）
    private var volumeElements: [UInt32] {
        guard deviceID != .unknown else { return [] }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return [0]
        }

        let audioBufferList = AudioBufferList.allocate(maximumBuffers: Int(size) / MemoryLayout<AudioBuffer>.size)
        defer { free(audioBufferList.unsafeMutablePointer) }

        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, audioBufferList.unsafeMutablePointer) == noErr else {
            return [0]
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList.unsafeMutablePointer)
        var totalChannels = 0
        for buffer in buffers {
            totalChannels += Int(buffer.mNumberChannels)
        }

        return totalChannels >= 2 ? [0, 1] : [0]
    }

    private func defaultOutputDeviceID() -> AudioObjectID {
        var addr = defaultOutputAddress
        var deviceID = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return .unknown }
        return deviceID
    }
}
