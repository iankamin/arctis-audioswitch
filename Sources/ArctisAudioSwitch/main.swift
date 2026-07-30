// main.swift - arctis-audioswitch daemon entry point.
//
// Watches the Arctis Nova Pro Wireless base station and follows the headset:
// powered on  -> make the Arctis the default input and output
// powered off -> restore the last non-Arctis default, else built-in
//
// Managed by bin/arctis. Protocol notes in captures/protocol.md.

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let version = "1.0.3"

// ---------------------------------------------------------------- paths

let appSupport = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ArctisNovaPro", isDirectory: true)
let stateURL = appSupport.appendingPathComponent("state.json")

// ---------------------------------------------------------------- args

var verbose = false
var command = "run"

for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "-v", "--verbose": verbose = true
    case "--list": command = "list"
    case "--status": command = "status"
    case "--version": command = "version"
    case "-h", "--help": command = "help"
    default:
        FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
        exit(2)
    }
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    print("[\(timeFormatter.string(from: Date()))] \(message)")
}

func debug(_ message: String) {
    if verbose { log(message) }
}

// ---------------------------------------------------------------- commands

switch command {
case "help":
    print("""
    arctis-audioswitch \(version) - follow the Arctis Nova Pro Wireless headset

      (no args)     run in the foreground, watching for headset power events
      -v, --verbose extra logging
      --status      show current and remembered devices, then exit
      --list        list all CoreAudio devices, then exit
      --version     print version
      -h, --help    this text

    Normally managed by `bin/arctis` rather than run directly.
    """)
    exit(0)

case "version":
    print(version)
    exit(0)

case "list":
    for device in Audio.devices() {
        var tags: [String] = []
        if device.hasOutput { tags.append("out") }
        if device.hasInput { tags.append("in") }
        if device.isBuiltIn { tags.append("built-in") }
        print("\(device.name)")
        print("    uid: \(device.uid)")
        print("    \(tags.joined(separator: ", "))")
    }
    exit(0)

case "status":
    let switcher = Switcher(stateURL: stateURL, log: { _ in })
    print("arctis-audioswitch \(version)")
    print(switcher.describeState())
    let monitor = HIDMonitor()
    monitor.log = { print("  \($0)") }
    if monitor.start() {
        let state = monitor.queryInitialState()
        print("  headset: \(state?.rawValue ?? "unknown")")
        monitor.stop()
    }
    exit(0)

default:
    break
}

// ---------------------------------------------------------------- run

log("arctis-audioswitch \(version) starting")

let switcher = Switcher(stateURL: stateURL, log: log)
let monitor = HIDMonitor()
monitor.log = { debug($0) }

guard monitor.start() else {
    log("fatal: could not attach to the base station - is it plugged in?")
    exit(1)
}

switcher.startObserving()

// A headset already on at launch produces no push event, so establish the
// starting state explicitly rather than assuming it is off.
if let initial = monitor.queryInitialState() {
    log("initial headset state: \(initial.rawValue)")
    // Deliberately not `apply` - at startup an already-off headset means the
    // current devices are the user's own choice and must not be overridden.
    switcher.applyInitial(initial)
} else {
    log("could not determine initial headset state; waiting for the next event")
}

monitor.onStateChange = { state in
    log("event: headset \(state.rawValue)")
    switcher.apply(state)
}

// Clean shutdown so launchd restarts are tidy.
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    log("stopping")
    monitor.stop()
    exit(0)
}
sigintSource.resume()
signal(SIGINT, SIG_IGN)

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    log("stopping")
    monitor.stop()
    exit(0)
}
sigtermSource.resume()
signal(SIGTERM, SIG_IGN)

log("watching for headset power events")
CFRunLoopRun()
