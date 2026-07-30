// Audio.swift - CoreAudio device enumeration and default-device switching.
//
// Devices are tracked by UID rather than AudioDeviceID: IDs are reassigned
// across reboots and re-plugs, UIDs are stable, and this daemon has to
// remember a device across exactly those events.

import Foundation
import CoreAudio

enum Scope {
    case output, input

    var defaultSelector: AudioObjectPropertySelector {
        switch self {
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        }
    }

    var streamScope: AudioObjectPropertyScope {
        switch self {
        case .output: return kAudioObjectPropertyScopeOutput
        case .input: return kAudioObjectPropertyScopeInput
        }
    }

    var label: String {
        switch self {
        case .output: return "output"
        case .input: return "input"
        }
    }
}

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let hasOutput: Bool
    let hasInput: Bool

    func supports(_ scope: Scope) -> Bool {
        scope == .output ? hasOutput : hasInput
    }
}

enum Audio {

    // MARK: - property helpers

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let str = value else { return nil }
        return str as String
    }

    private static func uint32Property(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    /// A device "supports" a scope only if it actually exposes channels there.
    /// The Arctis base station reports both, the built-in mic only input, etc.
    private static func hasChannels(_ deviceID: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        for buffer in list where buffer.mNumberChannels > 0 { return true }
        return false
    }

    // MARK: - enumeration

    static func devices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id -> AudioDevice? in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            let transport = uint32Property(id, kAudioDevicePropertyTransportType)
            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                hasOutput: hasChannels(id, kAudioObjectPropertyScopeOutput),
                hasInput: hasChannels(id, kAudioObjectPropertyScopeInput))
        }
    }

    static func device(uid: String) -> AudioDevice? {
        devices().first { $0.uid == uid }
    }

    /// Canonical UIDs Apple uses for the internal speakers and microphone.
    /// These are stable across reboots and macOS versions.
    private static func canonicalBuiltInUID(_ scope: Scope) -> String {
        switch scope {
        case .output: return "BuiltInSpeakerDevice"
        case .input: return "BuiltInMicrophoneDevice"
        }
    }

    /// Last-resort fallback when the remembered device is unavailable.
    ///
    /// Prefers the canonical internal speaker/mic by UID. Selecting merely the
    /// first device with a built-in transport type is unreliable: a Mac can
    /// expose several (and aggregate or virtual devices sometimes report as
    /// built-in), so "first match" can land on the wrong one.
    static func builtIn(for scope: Scope) -> AudioDevice? {
        let all = devices()
        let wanted = canonicalBuiltInUID(scope)

        if let exact = all.first(where: { $0.uid == wanted && $0.supports(scope) }) {
            return exact
        }
        // Older or unusual hardware may not use the canonical UID.
        return all.first { $0.isBuiltIn && $0.supports(scope) }
    }

    // MARK: - defaults

    static func currentDefault(_ scope: Scope) -> AudioDevice? {
        var addr = address(scope.defaultSelector)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var id: AudioDeviceID = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else {
            return nil
        }
        return devices().first { $0.id == id }
    }

    @discardableResult
    static func setDefault(_ scope: Scope, to device: AudioDevice) -> Bool {
        var addr = address(scope.defaultSelector)
        var id = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id)
        return status == noErr
    }

    // MARK: - change notifications

    private static var listenerBlocks: [AudioObjectPropertyListenerBlock] = []

    /// Fires when the user (or anything else) changes the system default for
    /// `scope`. Used to learn which device to fall back to on disconnect.
    static func observeDefaultChange(_ scope: Scope, handler: @escaping () -> Void) {
        var addr = address(scope.defaultSelector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        listenerBlocks.append(block)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block)
    }
}
