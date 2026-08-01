// main.swift - arctis-audioswitch daemon entry point.
//
// Watches the Arctis Nova Pro Wireless base station and follows the headset:
// powered on  -> make the Arctis the default input and output
// powered off -> restore the last non-Arctis default, else built-in
//
// Managed by bin/arctis. Protocol notes in captures/protocol.md.

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let version = "1.3.1"

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
        if monitor.isAttached {
            let state = monitor.queryInitialState()
            print("  headset: \(state?.rawValue ?? "unknown")")
        } else {
            print("  headset: unknown (base station not plugged in)")
        }
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

// Only a manager that will not open is fatal. A station that is not plugged in
// is normal - we wait for it. Exiting here used to be a permanent silent death:
// KeepAlive is { Crashed: true }, and a clean exit is not a crash, so launchd
// never retried if it started us before USB enumeration finished at login.
guard monitor.start() else {
    log("fatal: could not open IOHIDManager")
    exit(1)
}

// launchd starts us from a com.apple.iokit.matching device-attach event, and
// jobs launched that way are expected to consume it. Leaving it undrained lets
// launchd treat the event as undelivered and relaunch - and since this process
// exits as soon as the station is gone, that is the shape of a respawn loop.
// The payload tells us nothing IOHIDManager has not already said, so this
// handler exists purely to acknowledge. Must be registered before the run loop.
xpc_set_event_stream_handler("com.apple.iokit.matching", DispatchQueue.main) { _ in
    debug("drained a com.apple.iokit.matching event")
}

// Nothing to watch without the station. Exit rather than sitting resident: the
// LaunchEvents entry in the plist has launchd start us again on device-attach.
// RunAtLoad covers the other ordering - a station already present at login.
guard monitor.isAttached else {
    log("no base station; exiting until one is plugged in")
    monitor.stop()
    exit(0)
}

switcher.startObserving()

monitor.onStateChange = { state in
    log("event: headset \(state.rawValue)")
    switcher.apply(state)
}

// Fires at startup if the station is already plugged in, and again on every
// replug. Either way `applyInitial`, not `apply`: an off headset means the
// current devices are the user's own choice and must not be overridden.
monitor.onAttach = { witnessed in
    if witnessed {
        // We watched the station connect, so the headset is off, and the
        // station is still bringing its wireless link up and cannot answer a
        // status query yet. Seed it and wait for the power-on push event.
        // applyInitial still earns its place here: macOS will sometimes make a
        // newly appeared USB audio device the default on its own, and this
        // pulls us back off the Arctis when it does.
        monitor.seed(.disconnected)
        log("base station attached; headset off")
        switcher.applyInitial(.disconnected)
    } else if let initial = monitor.queryInitialState() {
        // Already plugged in when we started - it may have been for hours, so
        // the headset could be on. No push event describes that, so ask.
        log("initial headset state: \(initial.rawValue)")
        switcher.applyInitial(initial)
    } else {
        // Launched from a device-attach event, the station is present but was
        // plugged in seconds ago, so the sweep sees it as pre-existing while it
        // is still too cold to answer `06 b0`. Silence here means exactly that,
        // and the headset is always off at the moment the station connects.
        monitor.seed(.disconnected)
        log("station not answering yet; assuming headset off")
        switcher.applyInitial(.disconnected)
    }
}

// Exit rather than hold a dead reference. launchd restarts us on the next
// device-attach, so the process never outlives the station it is bound to -
// which is what makes the stale-IOHIDDevice bug structurally impossible.
monitor.onDetach = {
    log("base station unplugged; exiting until it comes back")
    monitor.stop()
    exit(0)
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
