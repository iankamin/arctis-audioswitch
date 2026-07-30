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

    /// The specific headset this daemon manages. Used to decide what to switch
    /// TO when it powers on, so it is deliberately precise.
    private static let targetMarker = "arctis nova pro"

    /// Broader marker used only to decide what must never be chosen while the
    /// headset is off. Any Arctis is excluded, so a second Arctis on the
    /// system can never silently become the "off" device either.
    private static let neverFallbackMarker = "arctis"

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

    private func matches(_ device: AudioDevice, _ marker: String) -> Bool {
        device.name.lowercased().contains(marker)
            || device.uid.lowercased().contains(marker)
    }

    /// Is this the headset we manage? Used when switching TO it.
    private func isTargetHeadset(_ device: AudioDevice) -> Bool {
        matches(device, Switcher.targetMarker)
    }

    /// Is this a device that must never be selected while the headset is off,
    /// or recorded as somewhere to fall back to? Broader than
    /// `isTargetHeadset` on purpose - see `neverFallbackMarker`.
    private func isNeverFallback(_ device: AudioDevice) -> Bool {
        matches(device, Switcher.neverFallbackMarker)
    }

    private func arctisDevice(for scope: Scope) -> AudioDevice? {
        Audio.devices().first { isTargetHeadset($0) && $0.supports(scope) }
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
        // Never record a headset as somewhere to fall back to.
        guard let current = Audio.currentDefault(scope), !isNeverFallback(current) else { return }

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
        let changed: [String]
        switch headset {
        case .connected: changed = switchToArctis()
        case .disconnected: changed = restoreFallback()
        }

        // One banner per transition rather than one per scope: output and
        // input almost always move together, and two stacked banners for a
        // single headset toggle is noise.
        guard !changed.isEmpty else { return }
        Notifier.post(
            title: headset == .connected ? "Headset connected" : "Headset disconnected",
            body: changed.joined(separator: "\n"))
    }

    @discardableResult
    private func switchToArctis() -> [String] {
        // Capture where we are now - this is the most reliable moment to learn
        // what the user was using before the headset came up.
        for scope in [Scope.output, Scope.input] {
            if let current = Audio.currentDefault(scope), !isNeverFallback(current) {
                switch scope {
                case .output: state.lastOutputUID = current.uid
                case .input: state.lastInputUID = current.uid
                }
            }
        }
        save()

        suppressObservationUntil = Date().addingTimeInterval(2.0)
        var changed: [String] = []
        for scope in [Scope.output, Scope.input] {
            guard let arctis = arctisDevice(for: scope) else {
                log("headset on: no Arctis \(scope.label) device found")
                continue
            }
            if Audio.setDefault(scope, to: arctis) {
                log("headset on: \(scope.label) -> \(arctis.name)")
                changed.append("\(scope.label.capitalized): \(arctis.name)")
            } else {
                log("headset on: FAILED to set \(scope.label) -> \(arctis.name)")
            }
        }
        return changed
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
            // Stale only if it is still pointing at the headset we manage.
            if isTargetHeadset(current) {
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

    @discardableResult
    private func restoreFallback() -> [String] {
        suppressObservationUntil = Date().addingTimeInterval(2.0)
        return [Scope.output, Scope.input].compactMap { restoreFallback(for: $0) }
    }

    /// Returns a human-readable description of the change, or nil if nothing
    /// was switched.
    @discardableResult
    private func restoreFallback(for scope: Scope) -> String? {
        suppressObservationUntil = Date().addingTimeInterval(2.0)

        let savedUID = scope == .output ? state.lastOutputUID : state.lastInputUID

        // Candidates in priority order:
        //   1. the remembered device
        //   2. the built-in speaker / microphone
        //   3. any other usable device
        var candidates: [AudioDevice] = []
        if let uid = savedUID, let saved = Audio.device(uid: uid) {
            candidates.append(saved)
        }
        if let builtIn = Audio.builtIn(for: scope) {
            candidates.append(builtIn)
        }
        candidates.append(contentsOf: Audio.devices())

        // THE invariant for the off state: never select the headset itself.
        // Routing to a powered-off headset produces silence with no visible
        // cause, so filter it out of every candidate at one choke point
        // rather than guarding each branch separately.
        let usable = candidates.filter { $0.supports(scope) && !isNeverFallback($0) }

        guard let device = usable.first else {
            // Leaving the current device alone is strictly better than
            // selecting the headset.
            log("headset off: no non-headset \(scope.label) device available, leaving as-is")
            return nil
        }

        if let uid = savedUID, device.uid != uid {
            log("headset off: saved \(scope.label) device unavailable, using \(device.name)")
        }

        if Audio.setDefault(scope, to: device) {
            log("headset off: \(scope.label) -> \(device.name)")
            return "\(scope.label.capitalized): \(device.name)"
        } else {
            log("headset off: FAILED to set \(scope.label) -> \(device.name)")
            return nil
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
