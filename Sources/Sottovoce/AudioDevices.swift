import Combine
import CoreAudio
import Foundation

/// A Core Audio input device.
///
/// Identified by its UID, not by its `AudioDeviceID`: the numeric id is handed
/// out by Core Audio at runtime and is reassigned across reboots and
/// reconnections, so storing it in a preference would silently start pointing
/// at a different microphone. The UID is stable for a given piece of hardware.
struct AudioInputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum AudioDevices {
    /// Every input-capable device, in the order Core Audio reports them.
    static func inputs() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInput(id), let uid = uid(of: id), let name = name(of: id) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// What the system would pick on its own — used to label the "System
    /// default" row with the device it currently resolves to.
    static func systemDefaultInput() -> AudioInputDevice? {
        guard let id = systemDefaultInputID(), let uid = uid(of: id), let name = name(of: id) else {
            return nil
        }
        return AudioInputDevice(uid: uid, name: name)
    }

    static func systemDefaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// Resolves a stored UID back to the ephemeral id the audio unit wants.
    /// `nil` means the device isn't currently attached.
    static func deviceID(uid wanted: String) -> AudioDeviceID? {
        allDeviceIDs().first { hasInput($0) && uid(of: $0) == wanted }
    }

    static func name(uid wanted: String) -> String? {
        deviceID(uid: wanted).flatMap { name(of: $0) }
    }
}

// MARK: - Core Audio plumbing

private extension AudioDevices {
    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// Output-only devices answer with an empty input stream configuration,
    /// which is how they're told apart from microphones.
    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    /// These properties follow Core Foundation's copy semantics — the string
    /// comes back retained, hence `takeRetainedValue`.
    static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    static func uid(of id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }
    static func name(of id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }
}

// MARK: - Live list for Settings

/// Keeps the device list fresh while Settings is open. Core Audio notifies on
/// devices appearing and disappearing and on the default input changing, so the
/// picker doesn't go stale when AirPods connect halfway through.
@MainActor
final class AudioInputDeviceList: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var systemDefault: AudioInputDevice?

    private var addresses: [AudioObjectPropertyAddress] = []
    private var listeners: [AudioObjectPropertyListenerBlock] = []

    init() {
        refresh()
        observe(kAudioHardwarePropertyDevices)
        observe(kAudioHardwarePropertyDefaultInputDevice)
    }

    deinit {
        // deinit isn't main-actor isolated; the listener blocks only touch
        // Core Audio, which is thread-safe for removal.
        for (address, block) in zip(addresses, listeners) {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
        }
    }

    func refresh() {
        devices = AudioDevices.inputs()
        systemDefault = AudioDevices.systemDefaultInput()
    }

    private func observe(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        ) == noErr else { return }
        addresses.append(address)
        listeners.append(block)
    }
}
