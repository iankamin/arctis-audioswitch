# arctis-audioswitch — working notes

Automatic macOS audio switching for the SteelSeries Arctis Nova Pro Wireless.
Apple Silicon only. See `README.md` for user-facing docs and
`captures/protocol.md` for the reverse-engineered HID protocol.

## Why this exists at all

The base station stays enumerated as a USB audio device whether or not the
headset is powered on, so CoreAudio's device list is **identical** in both
states. macOS cannot tell the headset came or went. The station does know, and
says so over a vendor-defined HID interface (`0x1038:0x12E0`, usage page
`0xFFC0`). The daemon listens to that and moves the default device.

Usage page `0xFFC0` is not a protected one — no Input Monitoring prompt, no
kernel extension.

## Layout

| File | Role |
|---|---|
| `Sources/ArctisAudioSwitch/HID.swift` | Finds the base station and turns its reports into `connected`/`disconnected` |
| `Sources/ArctisAudioSwitch/Switcher.swift` | Moves CoreAudio defaults, remembers fallbacks |
| `Sources/ArctisAudioSwitch/Audio.swift` | CoreAudio HAL wrapper |
| `Sources/ArctisAudioSwitch/Settings.swift` | `settings.json` (banner preference) |
| `Sources/ArctisAudioSwitch/Notifier.swift` | Notification banners |
| `Sources/ArctisAudioSwitch/main.swift` | Entry point, arg parsing, wiring |
| `bin/arctis` | User-facing CLI — install/enable/status/logs/update |
| `tools/probe.swift` | Protocol reverse-engineering tool |

## Hard-won facts — do not rediscover these

**Device lifecycle.** Find the station by *identity* (`IOHIDManagerSetDeviceMatching`
on vendor + product + usage page), never by USB port or location ID. Location
encodes hub/port topology and changes when the cable moves, so matching on it
breaks the "any port, any time" requirement. Location is logged on attach for
diagnostics only.

The `IOHIDManager` must be scheduled on the run loop and must register
*matching and removal* callbacks. Scheduling only the `IOHIDDevice` binds the
process to the one device object that existed at startup; unplugging destroys
it, replugging creates a new one, and the daemon stays alive and healthy-looking
while never hearing another report. That was the v1.2.1 bug.

**Match `07 b5` on byte 1 and byte 4 only — bytes 2-3 are not constant.**
`captures/protocol.md` used to call `07 b5 04 01 XX` a constant signature, and
`HID.swift` matched all four bytes. On 2026-07-31 a station that had just been
replugged began pushing `07 b5 01 00 XX` — same events, different bytes 2-3 —
and the four-byte check dropped every power event *silently*, with no log line
at any verbosity. The daemon looked perfectly healthy and audio simply stopped
switching. Byte 1 is the subcommand discriminator; byte 4 is the state. What
bytes 2-3 mean is still unknown.

Diagnosing it took `tools/probe.swift --no-poll` running beside the daemon: the
probe showed the events arriving on the wire ~100ms after the button, while the
daemon logged nothing. **That side-by-side is the technique to reach for** when
the daemon seems deaf — it separates "the station is not sending" from "we are
not accepting".

Beware of `arctis status` while diagnosing. It sends `06 b0`, and the reply goes
to *every* open client, so it re-syncs the running daemon through
`handleStatus`. That masked this bug repeatedly — state changes appeared to
work, but only ever within a second of a status query.

**Two protocol timing facts** (from Ian, not derivable from the captures):

1. The station **cannot answer `06 b0` immediately** after being plugged in —
   it is cold-booting and bringing its 2.4GHz link up. Do not query it on
   attach, and do not build a settle/retry window around it.
2. **At the moment the station connects to the computer, the headset is always
   off.** So a witnessed connect seeds `disconnected` directly, no query needed.
   This does *not* hold at daemon startup with the station already plugged in —
   it may have been there for hours with the headset on, which is what
   `queryInitialState()` is for. `HID.swift` distinguishes these via
   `sweepComplete`.

**Exiting when the station is absent is safe *only* because `LaunchEvents`
restarts us.** The LaunchAgent has `KeepAlive = { Crashed: true }`, and a clean
exit is *not* a crash, so launchd will never retry on its own. In v1.2.1 that
combination meant a permanent silent death whenever the station was missing at
launch. Since v1.3.0 the plist carries a `com.apple.iokit.matching`
device-attach entry, which is what brings the daemon back — so if you ever
remove or break `LaunchEvents`, you must also stop the daemon exiting, or the
v1.2.1 bug returns by a different route.

`RunAtLoad` stays `true` alongside it and covers the other ordering, a station
already attached at login. That combination also means it does not matter
whether device-attach fires for an already-present device — which was the one
`LaunchEvents` unknown that could have caused a silent regression.

**Seeding must not fire `onStateChange`.** It would make `switcher.apply`
override whatever device the user chose. Use `applyInitial`, which adopts the
current devices as the fallback baseline — and which also pulls the default off
the Arctis if macOS grabbed the re-enumerated USB audio device on its own.

**Resource constraint.** The daemon must stay event-driven — no timers, no
polling. Measured 0.09s CPU / 13.5MB RSS over 12 minutes, ~0% CPU. Any change
that introduces a poll loop is wrong. Since v1.3.0 it is also not resident at
all unless the station is plugged in.

**The XPC event stream must stay drained.** Jobs launched from
`com.apple.iokit.matching` are expected to consume the event, and this daemon
exits as soon as the station is gone — undrained events plus a short-lived
process is the shape of a respawn loop. `main.swift` registers
`xpc_set_event_stream_handler` before the run loop for no reason other than to
acknowledge. Do not remove it because the handler body looks empty.

Watch `runs =` in `launchctl print` if anything here is touched: a loop shows up
there as a climbing count, and it can be slow enough that a short test misses
it.

**A station found by the startup sweep has not necessarily been there long.**
Under `LaunchEvents` every attach starts a *fresh* process, so the sweep sees a
station that connected seconds ago as pre-existing and queries it — and it is
still too cold to answer. A `06 b0` timeout therefore means "just plugged in",
which by the invariant above means the headset is off. That is why the timeout
branch seeds `disconnected` rather than giving up.

## Resource discipline

`RESOURCES.md` is a manifest of **everything** this project creates, inside and
outside the repo, and `teardown.sh` must handle everything listed there. Add the
manifest row *before* creating the resource. The LaunchAgent survives reboots
and survives deleting the repo, so deleting the project folder is not
sufficient cleanup.

When checking whether a process is really gone, identify it by its **resolved
executable** (`lsof -a -p PID -d txt`), not `pgrep -f` or `ps -o comm=` — those
report the path as invoked, so a process started as `./build/foo` is invisible
to a pattern matching the absolute path.

## Workflow

```sh
swift build -c release           # build
.build/release/arctis-audioswitch --status
arctis logs -f                   # follow the live daemon
arctis restart                   # reload after install
```

Releases: bump `version` in `main.swift`, commit, tag `vX.Y.Z`, push with
`--follow-tags`. The `Release` workflow builds on `macos-14` and publishes both
a versioned and an unversioned tarball — the unversioned one exists so
`/releases/latest/download/<name>` works without knowing the version. Then
`arctis update` installs it and restarts the daemon.

**`update` rewrites the LaunchAgent every time** (via `arctis sync`, since
v1.3.1). It used to rewrite only when the recorded binary path had changed —
which never happens, the install path is fixed — so a release that changed the
plist shipped new code against the old plist and printed `LaunchAgent unchanged`
while doing it. v1.3.0 hit exactly that and had to be repaired by hand with
`arctis enable`. Note the fix only takes effect for the update *after* the one
that delivers it, because the installed `update` is what runs the swap.

`arctis sync` on its own is the repair for a stale LaunchAgent. Run the
*installed* copy, never the one in the repo — `bin/arctis` resolves paths from
its own location, so the repo copy would repoint the LaunchAgent at the repo
build.

Remove `build/` and `.build/` after cutting a release (~129MB).

## Diagnosing "audio stopped switching"

Check these before touching the protocol — the decoding in
`captures/protocol.md` has never been the culprit:

```sh
launchctl print gui/$UID/io.github.iankamin.arctis-audioswitch  # runs / pid / exit code
tail -40 "$TMPDIR/arctis-audioswitch/audioswitch.log"
ioreg -c IOHIDDevice -r -l -w 0 | grep -E 'VendorID|ProductID|PrimaryUsagePage'
# expect VendorID 4152 (0x1038), ProductID 4832 (0x12E0), PrimaryUsagePage 65472 (0xFFC0)
```

The v1.2.1 signature was: daemon running with `runs = 1` and
`last exit code = (never exited)`, still logging `remembered output fallback`
lines (proving the run loop turns) but no `event: headset ...` lines since the
unplug. `arctis restart` worked around it.

## State as of v1.3.0 (2026-07-31)

`LaunchEvents` shipped, and **the full unplug/replug cycle is verified on
hardware** (2026-07-31, v1.3.1):

- Unplug → `base station unplugged; exiting until it comes back`,
  `last exit code = 0`, no process left at all.
- Replug → launchd restarted it ~1s later with no login and no manual command.
  `runs` incremented 1 → 2, which is how you tell launchd did it: `arctis
  restart` boots the job out and back in, resetting the count to 1, and leaves a
  `stopping` line in the log. Neither appeared.
- The cold-station path worked: `station not answering yet; assuming headset
  off`, then the real `event: headset connected` a minute later once the
  wireless link came up, and both defaults moved.

Still worth watching: `runs =` over a day of normal use, for a climbing count
that does not match plug events.

## v1.2.2 (2026-07-31) — superseded, kept for the verification record

Released and installed. **The replug fix is verified on hardware.**

Confirmed working (2026-07-31, from the daemon log):

- **Replug.** Unplug → `base station unplugged; leaving audio as-is`; replug →
  `base station attached; headset off`; then `event: headset connected` on the
  *new* device, plus a second clean on/off cycle afterwards. On v1.2.1
  everything after the replug was silence.
- **`applyInitial(.disconnected)` on replug does not grab the default.** macOS
  had already moved output to MacBook Pro Speakers when the USB device vanished;
  on replug it correctly left that alone rather than jumping to the Arctis.
- **Login with the station present and the headset already on.** The unwitnessed
  path queried and got `initial headset state: connected`, then switched.

Next steps (all against v1.3.1):

1. **Watch `runs =`** over a day of normal use. A climbing count with no
   corresponding plug events means the XPC event is not being drained and
   launchd is relaunching. `ThrottleInterval` defaults to 10s, so a loop is
   bounded but not harmless. Nothing seen so far, but one afternoon is not a
   day.
2. **Verify the login race**: log out with the station *unplugged*, log back
   in, then plug in. The daemon is now *expected* to exit at login and be
   restarted by device-attach, so this tests `LaunchEvents` at login rather than
   the old waiting behaviour.
3. **Verify sleep/wake**, which re-enumerates USB.
4. Remove the build output once settled (`rm -rf .build build`) and update the
   `RESOURCES.md` row.

Rollback is `gh release download v1.2.2`, which is also verified on hardware and
stays resident.

**When reading the log during a test, watch for races.** The `event:` line and
the `headset on:` lines it causes are written within the same second, so a
`tail` fired immediately after a transition can show the event with no switch
and look like a failure. It is not. Re-check before concluding anything.

One unexplained observation: at the 19:58 login there were ~11s between
`starting` and `watching for headset power events`. It resolved and worked, so
it is not urgent, but that gap covers `monitor.start()` and
`switcher.startObserving()` — likely CoreAudio or IOKit being slow to come up at
login. Worth a look if startup ever seems to hang.

Rollback is `gh release download v1.2.1` — `arctis update` only moves forward.
