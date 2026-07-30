// Settings.swift - user preferences, deliberately separate from state.json.
//
// state.json is daemon-owned runtime memory, rewritten on every device switch.
// Putting user settings in the same file would mean `arctis notify off` and a
// headset toggle racing to write it, with one silently losing. Different
// owners, different files.
//
// The daemon owns the format: the CLI changes settings by invoking
// `arctis-audioswitch --set-notify`, so nothing has to parse or emit JSON in
// shell.

import Foundation

struct Settings: Codable {
    var notifications: Bool

    static let defaults = Settings(notifications: true)

    static func load(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .defaults
        }
        return decoded
    }

    @discardableResult
    func save(to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(
                "could not write settings: \(error.localizedDescription)\n".data(using: .utf8)!)
            return false
        }
    }
}
