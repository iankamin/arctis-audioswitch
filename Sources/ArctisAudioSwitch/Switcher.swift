// Switcher.swift - decides which audio device to make default, and remembers
// where to go back to.
//
// "Restore the last device" cannot mean "whatever CoreAudio's default was a
// moment ago": the base station stays enumerated whether or not the headset is
// powered, so that would just read back the Arctis. Instead this tracks the
// last default that was NOT the Arctis, persists it by UID, and falls back to
// built-in when that device is gone.

import Foundation

struct SavedState: Codable {
    var lastOutputUID: String?
    var lastInputUID: String?
}

final class Switcher {

    /// Matched against both device name and UID.
    private static let arctisMarker = "arctis nova pro"

    private let stateURL: URL
    private var state: SavedState
    private var log: (String) -> Void

    /// Set while we apply our own changes, so the default-change listener does
    /// not record the Arctis as the "device to go back to".
    private var suppressObservationUntil = Date.distantPast

    init(stateURL: URL, log: @escaping (String) -> Void) {
        self.stateURL = stateURL
        self.log = log
        self.state = Switcher.load(from: stateURL)
    }

    // MARK: - persistence

    private static func load(from url: URL) -> SavedState {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SavedState.self, from: data) else {
            return SavedState()
        }
        return decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            log("warning: could not save state: \(error.localizedDescription)")
        }
    }

    // MARK: - identification

    private func isArctis(_ device: AudioDevice) -> Bool {
        let marker = Switcher.arctisMarker
        return device.name.lowercased().contains(marker)
            || device.uid.lowercased().contains(marker)
    }

    private func arctisDevice(for scope: Scope) -> AudioDevice? {
        Audio.devices().first { isArctis($0) && $0.supports(scope) }
    }

    // MARK: - observation

    /// Records the user's own device choices so we know where to return to.
    /// Ignores changes we caused ourselves, and never records the Arctis.
    func startObserving() {
        for scope in [Scope.output, Scope.input] {
            Audio.observeDefaultChange(scope) { [weak self] in
                self?.noteDefaultChanged(scope)
            }
        }
    }

    private func noteDefaultChanged(_ scope: Scope) {
        guard Date() >= suppressObservationUntil else { return }
        guard let current = Audio.currentDefault(scope), !isArctis(current) else { return }

        switch scope {
        case .output:
            guard state.lastOutputUID != current.uid else { return }
            state.lastOutputUID = current.uid
        case .input:
            guard state.lastInputUID != current.uid else { return }
            state.lastInputUID = current.uid
        }
        log("remembered \(scope.label) fallback: \(current.name)")
        save()
    }

    // MARK: - switching

    func apply(_ headset: HeadsetState) {
        switch headset {
        case .connected: switchToArctis()
        case .disconnected: restoreFallback()
        }
    }

    private func switchToArctis() {
        // Capture where we are now - this is the most reliable moment to learn
        // what the user was using before the headset came up.
        for scope in [Scope.output, Scope.input] {
            if let current = Audio.currentDefault(scope), !isArctis(current) {
                switch scope {
                case .output: state.lastOutputUID = current.uid
                case .input: state.lastInputUID = current.uid
                }
            }
        }
        save()

        suppressObservationUntil = Date().addingTimeInterval(2.0)
        for scope in [Scope.output, Scope.input] {
            guard let arctis = arctisDevice(for: scope) else {
                log("headset on: no Arctis \(scope.label) device found")
                continue
            }
            if Audio.setDefault(scope, to: arctis) {
                log("headset on: \(scope.label) -> \(arctis.name)")
            } else {
                log("headset on: FAILED to set \(scope.label) -> \(arctis.name)")
            }
        }
    }

    /// Startup is not the same as a live disconnect.
    ///
    /// On a live disconnect the Arctis is the current default and must be
    /// replaced. At startup with the headset already off, the current devices
    /// are whatever the user chose, and forcing the built-in speakers would
    /// override a perfectly good setting - which is exactly what a fresh
    /// install used to do, hijacking output to the laptop speakers on first
    /// launch. Only intervene if a default is stale, i.e. still the Arctis.
    func applyInitial(_ headset: HeadsetState) {
        guard headset == .disconnected else {
            switchToArctis()
            return
        }

        var untouched: [String] = []
        for scope in [Scope.output, Scope.input] {
            guard let current = Audio.currentDefault(scope) else { continue }
            if isArctis(current) {
                restoreFallback(for: scope)
            } else {
                // Adopt what is already in use as the fallback baseline.
                switch scope {
                case .output: state.lastOutputUID = current.uid
                case .input: state.lastInputUID = current.uid
                }
                untouched.append("\(scope.label)=\(current.name)")
            }
        }
        save()
        if !untouched.isEmpty {
            log("headset already off; leaving \(untouched.joined(separator: ", ")) as-is")
        }
    }

    private func restoreFallback() {
        suppressObservationUntil = Date().addingTimeInterval(2.0)
        for scope in [Scope.output, Scope.input] {
            restoreFallback(for: scope)
        }
    }

    private func restoreFallback(for scope: Scope) {
        suppressObservationUntil = Date().addingTimeInterval(2.0)

        let savedUID = scope == .output ? state.lastOutputUID : state.lastInputUID

        // Saved device first; built-in only if it is missing or unplugged.
        let target: AudioDevice?
        if let uid = savedUID, let saved = Audio.device(uid: uid),
           saved.supports(scope), !isArctis(saved) {
            target = saved
        } else {
            target = Audio.builtIn(for: scope)
            if savedUID != nil && target != nil {
                log("headset off: saved \(scope.label) device unavailable, using built-in")
            }
        }

        guard let device = target else {
            log("headset off: no \(scope.label) device available")
            return
        }
        if Audio.setDefault(scope, to: device) {
            log("headset off: \(scope.label) -> \(device.name)")
        } else {
            log("headset off: FAILED to set \(scope.label) -> \(device.name)")
        }
    }

    // MARK: - reporting

    func describeState() -> String {
        var lines: [String] = []
        for scope in [Scope.output, Scope.input] {
            let current = Audio.currentDefault(scope)?.name ?? "(none)"
            let savedUID = scope == .output ? state.lastOutputUID : state.lastInputUID
            let saved = savedUID.flatMap { Audio.device(uid: $0)?.name }
                ?? savedUID.map { "\($0) (not connected)" }
                ?? "(none recorded)"
            let builtIn = Audio.builtIn(for: scope)?.name ?? "(none found)"
            lines.append("  \(scope.label): current=\(current)  fallback=\(saved)")
            lines.append("    last resort (built-in): \(builtIn)")
        }
        return lines.joined(separator: "\n")
    }
}
