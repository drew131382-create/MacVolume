import CoreAudio
import Foundation

/// A user-selectable Core Audio device shown in the menu-bar panel.
struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32

    var iconName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "airpods"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return "cable.connector"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return "square.stack.3d.up"
        default:
            return "hifispeaker.fill"
        }
    }
}

/// Enumerates audio devices, changes the system defaults, and controls the
/// hardware volume/mute of the currently selected output device.
@MainActor
final class DeviceVolume {
    var onStateChange: (() -> Void)?

    private(set) var volume: Float = 1.0
    private(set) var isMuted = false
    private(set) var canSetVolume = false
    private(set) var canSetMute = false
    private(set) var inputDevices: [AudioDevice] = []
    private(set) var outputDevices: [AudioDevice] = []
    private(set) var selectedInputDeviceID: AudioObjectID = .unknown
    private(set) var selectedOutputDeviceID: AudioObjectID = .unknown

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
        unregisterDeviceListeners()
        for (id, address, block) in systemListeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(id, &mutableAddress, queue, block)
        }
        systemListeners.removeAll()
        deviceID = .unknown
    }

    // MARK: - Device Selection

    @discardableResult
    func selectInputDevice(_ id: AudioObjectID) -> Bool {
        guard inputDevices.contains(where: { $0.id == id }) else { return false }
        let success = setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultInputDevice)
        if success { refresh() }
        return success
    }

    @discardableResult
    func selectOutputDevice(_ id: AudioObjectID) -> Bool {
        guard outputDevices.contains(where: { $0.id == id }) else { return false }

        let success = setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard success else { return false }

        // Keep alerts/system sounds on the same route when the property is writable.
        _ = setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, logFailure: false)
        refresh()
        return true
    }

    private func setDefaultDevice(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        logFailure: Bool = true
    ) -> Bool {
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newID = id
        let status = AudioObjectSetPropertyData(
            systemID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &newID
        )
        if status != noErr, logFailure {
            NSLog("MacVolume: 切换音频设备失败 selector=\(selector), status=\(status)")
        }
        return status == noErr
    }

    // MARK: - Output Volume

    func setVolume(_ value: Float) {
        guard deviceID != .unknown else { return }
        let elements = propertyElements(selector: kAudioDevicePropertyVolumeScalar, requireSettable: true)
        guard !elements.isEmpty else { return }

        let clamped = max(0, min(1, value))
        var didSet = false
        for element in elements {
            var address = propertyAddress(selector: kAudioDevicePropertyVolumeScalar, element: element)
            var scalar = clamped
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr {
                didSet = true
            }
        }
        if didSet { volume = clamped }
        readState()
    }

    func setMuted(_ muted: Bool) {
        guard deviceID != .unknown else { return }
        let elements = propertyElements(selector: kAudioDevicePropertyMute, requireSettable: true)
        guard !elements.isEmpty else { return }

        var didSet = false
        for element in elements {
            var address = propertyAddress(selector: kAudioDevicePropertyMute, element: element)
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                didSet = true
            }
        }
        if didSet { isMuted = muted }
        readState()
    }

    // MARK: - Listeners

    private func registerSystemListeners() {
        registerSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice)
        registerSystemListener(selector: kAudioHardwarePropertyDefaultOutputDevice)
        registerSystemListener(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        registerSystemListener(selector: kAudioHardwarePropertyDevices)
    }

    private func registerSystemListener(selector: AudioObjectPropertySelector) {
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(systemID, &address, queue, block) == noErr {
            systemListeners.append((systemID, address, block))
        }
    }

    private func registerDeviceListeners() {
        guard deviceID != .unknown else { return }

        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute
        ]
        for selector in selectors {
            for element in propertyElements(selector: selector, requireSettable: false) {
                var address = propertyAddress(selector: selector, element: element)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    DispatchQueue.main.async { self?.readState() }
                }
                if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr {
                    deviceListeners.append((deviceID, address, block))
                }
            }
        }
    }

    private func unregisterDeviceListeners() {
        for (id, address, block) in deviceListeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(id, &mutableAddress, queue, block)
        }
        deviceListeners.removeAll()
    }

    // MARK: - State

    private func refresh() {
        let devices = allDevices()
        inputDevices = devices.filter { channelCount(for: $0.id, scope: kAudioObjectPropertyScopeInput) > 0 }
        outputDevices = devices.filter { channelCount(for: $0.id, scope: kAudioObjectPropertyScopeOutput) > 0 }
        selectedInputDeviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
        selectedOutputDeviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)

        if selectedOutputDeviceID != deviceID {
            unregisterDeviceListeners()
            deviceID = selectedOutputDeviceID
            registerDeviceListeners()
        }
        readState()
    }

    private func readState() {
        guard deviceID != .unknown else {
            canSetVolume = false
            canSetMute = false
            onStateChange?()
            return
        }

        let volumeElements = propertyElements(selector: kAudioDevicePropertyVolumeScalar, requireSettable: false)
        let mutableVolumeElements = propertyElements(selector: kAudioDevicePropertyVolumeScalar, requireSettable: true)
        let muteElements = propertyElements(selector: kAudioDevicePropertyMute, requireSettable: false)
        let mutableMuteElements = propertyElements(selector: kAudioDevicePropertyMute, requireSettable: true)
        canSetVolume = !mutableVolumeElements.isEmpty
        canSetMute = !mutableMuteElements.isEmpty

        var sum: Float = 0
        var count: Float = 0
        for element in volumeElements {
            var address = propertyAddress(selector: kAudioDevicePropertyVolumeScalar, element: element)
            var scalar: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &scalar) == noErr {
                sum += scalar
                count += 1
            }
        }
        if count > 0 { volume = max(0, min(1, sum / count)) }

        var muteWasRead = false
        var muted = false
        for element in muteElements {
            var address = propertyAddress(selector: kAudioDevicePropertyMute, element: element)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                muteWasRead = true
                muted = muted || value != 0
            }
        }
        isMuted = muteWasRead && muted
        onStateChange?()
    }

    // MARK: - Enumeration

    private func allDevices() -> [AudioDevice] {
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: .unknown, count: count)
        guard AudioObjectGetPropertyData(systemID, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard isAlive(id), let name = readString(id, selector: kAudioObjectPropertyName) else { return nil }
            // Private process-tap aggregate devices should never be user routes.
            guard !name.hasPrefix("MacVolume-") else { return nil }
            let uid = readString(id, selector: kAudioDevicePropertyDeviceUID) ?? String(id)
            let transport = readUInt32(id, selector: kAudioDevicePropertyTransportType) ?? kAudioDeviceTransportTypeUnknown
            return AudioDevice(id: id, uid: uid, name: name, transportType: transport)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        ) == noErr else { return .unknown }
        return id
    }

    private func isAlive(_ id: AudioObjectID) -> Bool {
        readUInt32(id, selector: kAudioDevicePropertyDeviceIsAlive) != 0
    }

    private func readString(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func readUInt32(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - Property Helpers

    private func propertyAddress(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    /// Prefer a device-wide main control. Otherwise use every channel control.
    private func propertyElements(
        selector: AudioObjectPropertySelector,
        requireSettable: Bool
    ) -> [AudioObjectPropertyElement] {
        guard deviceID != .unknown else { return [] }

        if supportsProperty(selector: selector, element: kAudioObjectPropertyElementMain, requireSettable: requireSettable) {
            return [kAudioObjectPropertyElementMain]
        }

        let channels = channelCount(for: deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard channels > 0 else { return [] }
        return (1...channels).compactMap { channel in
            let element = AudioObjectPropertyElement(channel)
            return supportsProperty(selector: selector, element: element, requireSettable: requireSettable)
                ? element
                : nil
        }
    }

    private func supportsProperty(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement,
        requireSettable: Bool
    ) -> Bool {
        var address = propertyAddress(selector: selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        guard requireSettable else { return true }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    private func channelCount(for id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { pointer.deallocate() }
        let bufferList = pointer.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
