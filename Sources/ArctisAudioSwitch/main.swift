// main.swift - arctis-audioswitch daemon entry point.
//
// Watches the Arctis Nova Pro Wireless base station and follows the headset:
// powered on  -> make the Arctis the default input and output
// powered off -> restore the last non-Arctis default, else built-in
//
// Managed by bin/arctis. Protocol notes in captures/protocol.md.

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let version = "1.2.1"

// ---------------------------------------------------------------- paths

let appSupport = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ArctisNovaPro", isDirectory: true)
let stateURL = appSupport.appendingPathComponent("state.json")
let settingsURL = appSupport.appendingPathComponent("settings.json")

Notifier.settingsURL = settingsURL

// ---------------------------------------------------------------- args

var verbose = false
var command = "run"
var setNotifyValue: Bool?

var argv = Array(CommandLine.arguments.dropFirst())
var argIndex = 0
while argIndex < argv.count {
    let arg = argv[argIndex]
    switch arg {
    case "-v", "--verbose": verbose = true
    // Override the stored setting for this run only - for foreground use.
    // The LaunchAgent passes neither and follows settings.json.
    case "--notify": Notifier.override = true
    case "--no-notify": Notifier.override = false
    case "--set-notify":
        argIndex += 1
        guard argIndex < argv.count, ["on", "off"].contains(argv[argIndex]) else {
            FileHandle.standardError.write("--set-notify requires on|off\n".data(using: .utf8)!)
            exit(2)
        }
        setNotifyValue = argv[argIndex] == "on"
        command = "set-notify"
    case "--get-notify": command = "get-notify"
    case "--list": command = "list"
    case "--status": command = "status"
    case "--version": command = "version"
    case "-h", "--help": command = "help"
    default:
        FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
        exit(2)
    }
    argIndex += 1
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
      --notify      force banners on for this run, ignoring the saved setting
      --no-notify   force banners off for this run
      --set-notify on|off
                    save the banner preference to settings.json
      --get-notify  print the saved banner preference
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

// The daemon owns settings.json so nothing else has to parse or emit JSON.
case "set-notify":
    var settings = Settings.load(from: settingsURL)
    settings.notifications = setNotifyValue ?? true
    guard settings.save(to: settingsURL) else { exit(1) }
    print(settings.notifications ? "on" : "off")
    exit(0)

case "get-notify":
    print(Settings.load(from: settingsURL).notifications ? "on" : "off")
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
