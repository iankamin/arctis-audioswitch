// probe.swift - reverse-engineering tool for the Arctis Nova Pro Wireless
// base station's vendor HID interface (usage page 0xFFC0).
//
// Goal: find which byte(s) change when the headset is powered on/off, so the
// daemon can watch for that transition. Prints timestamped hex and marks
// bytes that differ from the previous report with ^ underneath.
//
// Build: swiftc -O tools/probe.swift -o build/probe
// Run:   ./build/probe            # listen + poll status every 1s
//        ./build/probe --no-poll  # passive listen only
//        ./build/probe --cmd 06b0 --interval 0.5
//        ./build/probe --pad 64   # pad the poll command to 64 bytes

import Foundation
import IOKit
import IOKit.hid

// stdout is block-buffered when redirected to a file, which hides output until
// the buffer fills or the process exits - useless for a live capture.
setvbuf(stdout, nil, _IONBF, 0)

let VID = 0x1038
let PID = 0x12E0
let VENDOR_USAGE_PAGE = 0xFFC0

// ---------------------------------------------------------------- args

var pollCmd: [UInt8] = [0x06, 0xb0]
var interval: Double = 1.0
var doPoll = true
var padTo = 0

func parseHex(_ s: String) -> [UInt8]? {
    let clean = s.replacingOccurrences(of: " ", with: "")
                 .replacingOccurrences(of: "0x", with: "")
    guard clean.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
        out.append(b)
        i = j
    }
    return out
}

var argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    switch argv[ai] {
    case "--no-poll":
        doPoll = false
    case "--cmd":
        ai += 1
        guard ai < argv.count, let b = parseHex(argv[ai]) else {
            FileHandle.standardError.write("bad --cmd\n".data(using: .utf8)!); exit(2)
        }
        pollCmd = b
    case "--interval":
        ai += 1
        guard ai < argv.count, let v = Double(argv[ai]) else {
            FileHandle.standardError.write("bad --interval\n".data(using: .utf8)!); exit(2)
        }
        interval = v
    case "--pad":
        ai += 1
        guard ai < argv.count, let v = Int(argv[ai]) else {
            FileHandle.standardError.write("bad --pad\n".data(using: .utf8)!); exit(2)
        }
        padTo = v
    case "-h", "--help":
        print("""
        probe - dump the Arctis Nova Pro Wireless vendor HID interface

          --no-poll         passive listen only, send nothing
          --cmd HEX         status command to poll (default 06b0)
          --interval SEC    poll interval (default 1.0)
          --pad N           zero-pad the command to N bytes
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown arg: \(argv[ai])\n".data(using: .utf8)!)
        exit(2)
    }
    ai += 1
}

// ---------------------------------------------------------------- helpers

let tsFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func ts() -> String { tsFmt.string(from: Date()) }

func hexLine(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

/// Marks columns that changed relative to `prev` with a caret.
func diffLine(_ bytes: [UInt8], _ prev: [UInt8]?) -> String? {
    guard let prev = prev else { return nil }
    var marks: [String] = []
    var any = false
    for i in 0..<bytes.count {
        if i < prev.count && prev[i] == bytes[i] {
            marks.append("  ")
        } else {
            marks.append(" ^")
            any = true
        }
    }
    return any ? marks.joined(separator: " ") : nil
}

/// Trailing zero bytes carry no signal; trim them so the diff is readable.
func trimZeros(_ b: [UInt8]) -> [UInt8] {
    var end = b.count
    while end > 1 && b[end - 1] == 0 { end -= 1 }
    return Array(b[0..<end])
}

// ---------------------------------------------------------------- device

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: VID,
    kIOHIDProductIDKey as String: PID,
    kIOHIDPrimaryUsagePageKey as String: VENDOR_USAGE_PAGE,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    FileHandle.standardError.write(
        "IOHIDManagerOpen failed: \(String(format: "0x%08x", openResult))\n".data(using: .utf8)!)
    exit(1)
}

guard let devSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
      let device = devSet.first else {
    FileHandle.standardError.write(
        "no device matching \(String(format: "%04x:%04x", VID, PID)) usagePage \(String(format: "0x%04x", VENDOR_USAGE_PAGE))\n"
            .data(using: .utf8)!)
    exit(1)
}

func intProp(_ d: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(d, key as CFString) as? Int) ?? 0
}

let maxIn = max(intProp(device, kIOHIDMaxInputReportSizeKey as String), 64)

print("probe: Arctis Nova Pro Wireless vendor interface")
print("  \(String(format: "%04x:%04x", VID, PID))  usagePage 0x\(String(format: "%04x", VENDOR_USAGE_PAGE))  maxInputReport \(maxIn)")
if doPoll {
    var c = pollCmd
    if padTo > c.count { c += [UInt8](repeating: 0, count: padTo - c.count) }
    print("  polling [\(hexLine(c))] every \(interval)s")
} else {
    print("  passive listen only")
}
print("")
print("Toggle the headset ON and OFF. Watch for bytes marked ^")
print("Ctrl-C to stop.")
print(String(repeating: "-", count: 64))

// ---------------------------------------------------------------- listen

// Keyed by report ID: reports 6 and 7 are different messages entirely, so
// diffing them against a single shared "previous" produced meaningless marks.
var lastInput: [UInt32: [UInt8]] = [:]
let inputBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: maxIn)
inputBuf.initialize(repeating: 0, count: maxIn)

var lastReportAt = Date()

let inputCallback: IOHIDReportCallback = { _, result, _, type, reportID, report, length in
    guard result == kIOReturnSuccess, length > 0 else { return }
    let bytes = trimZeros(Array(UnsafeBufferPointer(start: report, count: length)))

    // The poll loop provokes an identical reply every tick. Printing all of
    // them buries the one report that matters, so only surface changes.
    let prev = lastInput[reportID]
    guard bytes != prev else { return }

    let d = diffLine(bytes, prev)
    let tag = (type == kIOHIDReportTypeInput) ? "IN " : "OTH"
    print("[\(ts())] \(tag) id=\(reportID) len=\(length)  *** CHANGED ***")
    print("           \(hexLine(bytes))")
    if let d = d { print("           \(d)") }
    // Index ruler makes it easy to name the byte offset that moved.
    print("           \((0..<bytes.count).map { String(format: "%2d", $0) }.joined(separator: " "))")
    print("")
    lastInput[reportID] = bytes
    lastReportAt = Date()
}

IOHIDDeviceRegisterInputReportCallback(device, inputBuf, maxIn, inputCallback, nil)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

// ---------------------------------------------------------------- poll

var lastPoll: [UInt8]? = nil

func pollOnce() {
    var cmd = pollCmd
    if padTo > cmd.count { cmd += [UInt8](repeating: 0, count: padTo - cmd.count) }

    let setRes = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0), cmd, cmd.count)
    if setRes != kIOReturnSuccess {
        print("[\(ts())] SetReport failed: \(String(format: "0x%08x", setRes))")
        return
    }

    var buf = [UInt8](repeating: 0, count: maxIn)
    var len = CFIndex(maxIn)
    let getRes = buf.withUnsafeMutableBufferPointer { p -> IOReturn in
        IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(0), p.baseAddress!, &len)
    }
    guard getRes == kIOReturnSuccess, len > 0 else { return }

    let bytes = trimZeros(Array(buf[0..<len]))
    // Only print when something actually changed - keeps the log readable
    // across long idle stretches.
    if bytes != lastPoll {
        let d = diffLine(bytes, lastPoll)
        print("[\(ts())] POLL len=\(len)")
        print("           \(hexLine(bytes))")
        if let d = d { print("           \(d)") }
        lastPoll = bytes
    }
}

if doPoll {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in pollOnce() }
    RunLoop.current.add(timer, forMode: .default)
    pollOnce()
}

// Heartbeat so a quiet capture is distinguishable from a hung one.
let heartbeat = Timer(timeInterval: 15.0, repeats: true) { _ in
    let idle = Int(Date().timeIntervalSince(lastReportAt))
    print("[\(ts())] ... alive, no change for \(idle)s")
}
RunLoop.current.add(heartbeat, forMode: .default)

signal(SIGINT) { _ in
    print("\nstopped.")
    exit(0)
}

CFRunLoopRun()
