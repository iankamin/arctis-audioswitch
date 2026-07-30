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
    var log: (String) -> Void = { _ in }

    private var lastState: HeadsetState?

    // MARK: - lifecycle

    func start() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: Self.usagePage,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log("error: could not open IOHIDManager")
            return false
        }
        guard let found = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>)?.first else {
            log("error: base station not found (\(String(format: "%04x:%04x", Self.vendorID, Self.productID)))")
            return false
        }

        manager = mgr
        device = found

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        buf.initialize(repeating: 0, count: bufferSize)
        buffer = buf

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(found, buf, bufferSize, { ctx, result, _, _, reportID, report, length in
            guard result == kIOReturnSuccess, length > 0, let ctx = ctx else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            monitor.handle(reportID: reportID, bytes: bytes)
        }, context)

        IOHIDDeviceScheduleWithRunLoop(found, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        log("watching base station \(String(format: "%04x:%04x", Self.vendorID, Self.productID)) usagePage 0x\(String(format: "%04x", Self.usagePage))")
        return true
    }

    func stop() {
        if let device = device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        if let manager = manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        buffer?.deallocate()
        buffer = nil
        device = nil
        manager = nil
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
        onStateChange?(state)
    }

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
