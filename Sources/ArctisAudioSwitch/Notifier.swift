// Notifier.swift - macOS notification banners for device switches.
//
// Uses `osascript -e 'display notification ...'` rather than the
// UserNotifications framework. UNUserNotificationCenter.current() requires a
// bundle identifier and traps when called from a bare executable, and this
// daemon ships as a plain binary rather than an .app bundle. The tradeoff is
// that banners are attributed to "Script Editor" instead of to this tool;
// fixing that means shipping an .app wrapper.

import Foundation

enum Notifier {

    /// Where the preference lives. Set once at startup.
    static var settingsURL: URL?

    /// Set by `--notify` / `--no-notify`, which win over the stored setting.
    /// Intended for foreground runs; the LaunchAgent passes neither, so the
    /// daemon follows settings.json.
    static var override: Bool?

    /// Re-read per post rather than cached at startup, so `arctis notify off`
    /// takes effect immediately instead of needing the daemon restarted.
    /// Switches are rare, so the cost is irrelevant.
    static var enabled: Bool {
        if let override = override { return override }
        guard let url = settingsURL else { return Settings.defaults.notifications }
        return Settings.load(from: url).notifications
    }

    /// Escapes a Swift string into an AppleScript string literal.
    /// Device names are user-controlled (they can be renamed in Audio MIDI
    /// Setup), so a name containing a quote must not be able to terminate the
    /// literal and inject script.
    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func post(title: String, body: String) {
        guard enabled else { return }

        let script = "display notification \(appleScriptLiteral(body)) "
            + "with title \(appleScriptLiteral(title))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Off the run loop: this must never delay the audio switch itself,
        // and the child still has to be reaped.
        DispatchQueue.global(qos: .utility).async {
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // A missing or sandboxed osascript is not worth failing over.
            }
        }
    }
}
