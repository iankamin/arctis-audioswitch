// HID.swift - watches the Arctis Nova Pro Wireless base station for headset
// power on/off events.
//
// Protocol details and the captures they came from: captures/protocol.md
//
// The base station PUSHES state changes on report ID 7 - verified by capturing
// a full on/off cycle with the probe in --no-poll mode, sending the device
// nothing. So this is purely event-driven: no timer, no polling, idle at 0% CPU.

import Foundation
import IOKit
import IOKit.hid

enum HeadsetState: String {
    case connected
    case disconnected
}

final class HIDMonitor {

    static let vendorID = 0x1038
    static let productID = 0x12E0
    /// Vendor-defined usage page. Not a protected page, so no Input Monitoring
    /// permission is required to open it.
    static let usagePage = 0xFFC0

    // Connection event: 07 b5 04 01 XX
    // Bytes 1-3 are a constant signature; byte 4 carries the state. Verified
    // battery-independent across low- and high-battery power cycles, which is
    // what rules out the battery byte in report 6 as a trigger.
    private static let eventReportID: UInt32 = 7
    private static let signature: [UInt8] = [0x07, 0xb5, 0x04, 0x01]
    private static let stateConnected: UInt8 = 0x08
    private static let stateDisconnected: UInt8 = 0x04

    // Status reply to `06 b0`, used only to establish initial state at startup.
    private static let statusCommand: [UInt8] = [0x06, 0xb0]
    private static let statusReportID: UInt32 = 6
    private static let statusConnectionByte = 14   // 0x08 = on, 0x04 = off

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private let bufferSize = 64

    /// Called on every confirmed state transition. Repeat events for the state
    /// we are already in are filtered out before this fires.
    var onStateChange: ((HeadsetState) -> Void)?
    /// Fires whenever the base station appears - at startup if it is already
    /// plugged in, and again on every replug.
    ///
    /// `witnessed` is false for a station that was already there when we
    /// started looking: it may have been plugged in for hours, so the headset
    /// could be on and the state has to be asked for. It is true when we
    /// watched the connect happen, and then the headset is always off - the
    /// station is still bringing its wireless link up and cannot answer a
    /// status query that early anyway.
    var onAttach: ((_ witnessed: Bool) -> Void)?
    /// Fires when the base station goes away. Audio is deliberately left alone:
    /// unplugging the station is not the headset powering off.
    var onDetach: (() -> Void)?
    var log: (String) -> Void = { _ in }

    /// Whether the base station is plugged in right now.
    var isAttached: Bool { device != nil }

    private var lastState: HeadsetState?
    /// While seeding we record `lastState` without reporting a transition.
    private var isSeeding = false
    /// Set once the startup sweep has run, so the matching callback can tell a
    /// station it watched arrive from one that was already there.
    private var sweepComplete = false

    private var idString: String {
        String(format: "%04x:%04x", Self.vendorID, Self.productID)
    }

    // MARK: - lifecycle

    /// Opens the manager and attaches to the station if it is already plugged
    /// in. Returns false only if the manager itself could not be opened - a
    /// station that is not plugged in is not a failure, we wait for it.
    func start() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: Self.usagePage,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, result, _, device in
            guard result == kIOReturnSuccess, let ctx = ctx else { return }
            Unmanaged<HIDMonitor>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<HIDMonitor>.fromOpaque(ctx).takeUnretainedValue().detach(device)
        }, context)

        // The manager has to be on the run loop for those two callbacks to fire
        // at all. Scheduling only the device - which is what this used to do -
        // binds us to the one IOHIDDevice that existed at launch; unplugging
        // destroys it, replugging creates a new one, and we would sit holding
        // the dead reference forever, alive but deaf.
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            log("error: could not open IOHIDManager")
            return false
        }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        buf.initialize(repeating: 0, count: bufferSize)
        buffer = buf
        manager = mgr

        // Claim a station that is already plugged in synchronously, so callers
        // can query it without pumping the run loop first. The matching
        // callback fires for this same device once the run loop turns; `attach`
        // drops it as a duplicate.
        if let found = currentDevice(of: mgr) {
            attach(found)
        } else {
            log("base station \(idString) not attached; waiting for it")
        }
        sweepComplete = true
        return true
    }

    func stop() {
        if let device = device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        buffer?.deallocate()
        buffer = nil
        device = nil
        manager = nil
        sweepComplete = false
    }

    // MARK: - attach / detach

    /// `IOHIDManagerCopyDevices` returns an unordered set. Only one interface
    /// should match on this usage page, but pick deterministically rather than
    /// leaving it to hash order if that ever stops being true.
    private func currentDevice(of manager: IOHIDManager) -> IOHIDDevice? {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        return devices.min { lhs, rhs in
            (locationID(of: lhs) ?? UInt32.max) < (locationID(of: rhs) ?? UInt32.max)
        }
    }

    private func locationID(of device: IOHIDDevice) -> UInt32? {
        (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
    }

    private func attach(_ found: IOHIDDevice) {
        // The startup sweep and the matching callback both report a station
        // that was already plugged in; whichever gets there first wins.
        guard device == nil, let buf = buffer else { return }

        let witnessed = sweepComplete
        device = found

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(found, buf, bufferSize, { ctx, result, _, _, reportID, report, length in
            guard result == kIOReturnSuccess, length > 0, let ctx = ctx else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            monitor.handle(reportID: reportID, bytes: bytes)
        }, context)

        IOHIDDeviceScheduleWithRunLoop(found, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Location is logged, never matched on - we find the station by
        // identity so it works on any port or hub. It is here so that an odd
        // report later can be tied to the station having moved.
        let location = locationID(of: found).map { String(format: " location 0x%08x", $0) } ?? ""
        log("watching base station \(idString) usagePage 0x\(String(format: "%04x", Self.usagePage))\(location)")

        // Deferred: the handler re-seeds via queryInitialState(), which pumps
        // the run loop, and nesting that inside a run-loop callback is asking
        // for trouble.
        DispatchQueue.main.async { [weak self] in
            self?.onAttach?(witnessed)
        }
    }

    private func detach(_ lost: IOHIDDevice) {
        guard let current = device, CFEqual(current, lost) else { return }

        IOHIDDeviceUnscheduleFromRunLoop(current, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        device = nil
        // Nothing about the headset is observable while the station is gone, so
        // forget the state rather than trusting it when the station returns.
        lastState = nil
        log("base station detached; waiting for it to come back")

        DispatchQueue.main.async { [weak self] in
            self?.onDetach?()
        }
    }

    // MARK: - initial state

    /// No push event fires for a headset that was already on when we launched,
    /// so ask once at startup rather than assuming a state.
    ///
    /// The station does NOT answer a synchronous IOHIDDeviceGetReport - it
    /// replies asynchronously on the input-report callback. So this sends
    /// `06 b0` and pumps the run loop until that reply arrives.
    func queryInitialState(timeout: TimeInterval = 2.0) -> HeadsetState? {
        guard let device = device else { return nil }

        isSeeding = true
        defer { isSeeding = false }

        var cmd = Self.statusCommand
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0), &cmd, cmd.count) == kIOReturnSuccess else {
            log("initial state query: SetReport failed")
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while lastState == nil && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }

        if lastState == nil {
            log("initial state query: no reply within \(timeout)s")
        }
        return lastState
    }

    /// Record a state without reporting it as a transition. Used when we watch
    /// the station being plugged in: the headset is always off at that moment,
    /// and the station cannot answer `06 b0` that early.
    func seed(_ state: HeadsetState) {
        lastState = state
    }

    // MARK: - event handling

    private func handle(reportID: UInt32, bytes: [UInt8]) {
        switch reportID {
        case Self.eventReportID:
            handleEvent(bytes)
        case Self.statusReportID:
            handleStatus(bytes)
        default:
            break
        }
    }

    /// Report 7: `07 b5 04 01 XX`. Other subcommands (b7 battery, b9 volume,
    /// 2e ANC/transparency, bd) differ at byte 1 and are rejected by the
    /// signature check - verified against a capture that exercised volume,
    /// ANC, transparency and EQ without producing a single b5.
    private func handleEvent(_ bytes: [UInt8]) {
        guard bytes.count >= 5, Array(bytes[0..<4]) == Self.signature else { return }

        switch bytes[4] {
        case Self.stateConnected: update(.connected)
        case Self.stateDisconnected: update(.disconnected)
        default:
            log("unrecognised state byte 0x\(String(format: "%02x", bytes[4])) in \(hex(bytes.prefix(5)))")
        }
    }

    /// Report 6 arrives both as a reply to `06 b0` and unsolicited on change.
    /// Used to seed the initial state, and as a safety net that re-syncs us if
    /// a push event is ever missed.
    private func handleStatus(_ bytes: [UInt8]) {
        guard bytes.count > Self.statusConnectionByte + 1 else { return }

        let primary = bytes[Self.statusConnectionByte]        // 0x08 on / 0x04 off
        let secondary = bytes[Self.statusConnectionByte + 1]  // 0x08 on / 0x01 off

        let state: HeadsetState
        switch primary {
        case 0x08: state = .connected
        case 0x04: state = .disconnected
        default: return
        }

        // Both bytes were confirmed binary and battery-independent; disagreement
        // means the protocol assumption needs revisiting, so say so rather than
        // silently trusting one.
        let secondaryAgrees = (state == .connected) ? (secondary == 0x08) : (secondary == 0x01)
        if !secondaryAgrees {
            log("status bytes disagree: [14]=0x\(String(format: "%02x", primary)) [15]=0x\(String(format: "%02x", secondary)); trusting [14]")
        }

        update(state)
    }

    /// Single funnel for both report types. The station emits b5 and b7 and a
    /// status update per transition, so dedupe to one switch per real change.
    private func update(_ state: HeadsetState) {
        guard state != lastState else { return }
        lastState = state
        // Seeding records where we are without claiming the user just did
        // something. Firing here would have `switcher.apply` override whatever
        // device they had chosen while the station was away.
        guard !isSeeding else { return }
        onStateChange?(state)
    }

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
