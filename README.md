# arctis-audioswitch

Automatic macOS audio switching for the **SteelSeries Arctis Nova Pro Wireless**.

> **Apple Silicon (M-series) Macs only.**

Turn the headset on, it becomes your default input and output. Turn it off,
your previous devices come back.

```
$ arctis logs -f
[15:03:06] initial headset state: connected
[15:03:06] headset on: output -> Arctis Nova Pro Wireless
[15:03:06] headset on: input  -> Arctis Nova Pro Wireless
[15:03:25] event: headset disconnected
[15:03:25] headset off: output -> X34 V
[15:03:25] headset off: input  -> MacBook Pro Microphone
```

## Why this exists

The base station stays enumerated as a USB audio device whether or not the
headset is powered on. CoreAudio's device list is **identical** in both states,
so macOS has no idea the headset came or went — it just keeps sending audio to
a headset sitting on your desk, switched off.

The base station does know, and says so over a vendor-defined HID interface.
This daemon listens to that and moves the default device accordingly.

## Requirements

- **Apple Silicon (M-series) Mac only** — Intel Macs are not supported
- macOS 12 or later
- Arctis Nova Pro Wireless base station (USB `0x1038:0x12E0`)

No special permissions. The vendor HID usage page (`0xFFC0`) is not a protected
one, so there is **no Input Monitoring prompt** and no kernel extension.

## Install

### From a release

Always fetches the latest version — nothing to substitute:

```sh
mkdir -p ~/.local/share && cd ~/.local/share
curl -LO https://github.com/iankamin/arctis-audioswitch/releases/latest/download/arctis-audioswitch-macos-arm64.tar.gz
tar -xzf arctis-audioswitch-macos-arm64.tar.gz
rm arctis-audioswitch-macos-arm64.tar.gz
cd arctis-audioswitch
./bin/arctis install    # symlink `arctis` into ~/.local/bin
arctis enable           # start now, and at every login
```

> **Do not install into `~/Downloads`, `~/Desktop` or `~/Documents`.**
> Those are TCC-protected. The LaunchAgent runs the binary from wherever you
> put it, so installing there makes macOS raise a "wants to access files in
> your Downloads folder" prompt at login — and if it is ever denied, the
> daemon silently fails to start. `~/.local/share` is not protected.

`install` creates a symlink, it does not copy, so **keep the extracted
folder**. Deleting or moving it breaks the `arctis` command; if you do move
it, re-run `./bin/arctis install` from the new location.

To pin a specific version instead, every release also ships a versioned copy
of the same tarball, e.g.
`arctis-audioswitch-1.0.0-macos-arm64.tar.gz`. Both extract to
`arctis-audioswitch/`, so the steps above are unchanged.

Each asset has a matching `.sha256`:

```sh
shasum -a 256 -c arctis-audioswitch-macos-arm64.tar.gz.sha256
```

The released binary is ad-hoc signed, not notarized. Downloading through a
browser sets a quarantine flag that Gatekeeper will block; `curl` does not.
If you hit *"cannot be opened because the developer cannot be verified"*:

```sh
xattr -dr com.apple.quarantine arctis-audioswitch
```

No `sudo` is needed at any point — everything installs under your home
directory, and the LaunchAgent runs as you rather than as root.

### From source

```sh
git clone https://github.com/iankamin/arctis-audioswitch.git
cd arctis-audioswitch
./bin/arctis build      # swift build -c release
./bin/arctis install    # symlink `arctis` into ~/.local/bin
arctis enable           # start now, and at every login
```

`install` symlinks rather than copies, so the command follows this checkout and
rebuilds take effect immediately. Override the location with `ARCTIS_PREFIX`:

```sh
ARCTIS_PREFIX=/usr/local/bin ./bin/arctis install
```

## Usage

```
arctis start          start now; leaves start-at-login unchanged
arctis stop           stop now; leaves start-at-login unchanged
arctis restart

arctis enable         start at login, and start now
arctis disable        do not start at login, and stop now

arctis status         running? enabled? current and remembered devices
arctis logs [-f]      recent log output
arctis build          compile from Sources/

arctis install        put `arctis` on your PATH
arctis uninstall-cli  remove just that symlink
arctis uninstall      remove everything (see Uninstalling)
```

`start`/`stop` control it right now. `enable`/`disable` control whether it
comes back at login. They are deliberately independent.

## How the fallback works

"Restore the previous device" cannot mean "whatever CoreAudio's default was a
moment ago" — because the base station never disappears, that would just read
back the Arctis itself.

Instead the daemon tracks the last default that was **not** the Arctis, stores
it by device UID (stable across reboots and re-plugs, unlike device IDs), and
on disconnect restores that. If the remembered device is gone — an unplugged
monitor, a disconnected interface — it falls back to the built-in speakers and
microphone.

Your own manual choices are learned too: switch to another device while the
headset is on and that becomes the new fallback.

State lives in `~/Library/Application Support/ArctisNovaPro/state.json`.

Logs go to `$TMPDIR/arctis-audioswitch/` — the per-user temp directory, private
to your account — so the OS clears them and they never accumulate across
reboots. Read them with `arctis logs`.

## Protocol

Reverse-engineered from scratch; see [`captures/protocol.md`](captures/protocol.md)
for the full write-up and [`captures/`](captures/) for the raw HID dumps it was
derived from.

The short version — the base station pushes an event on report ID 7 when the
headset powers on or off:

```
headset on    07 b5 04 01 08
headset off   07 b5 04 01 04
```

Because these are pushed, the daemon does no polling: no timer, idle at 0% CPU,
reacting in about 100 ms.

Two findings worth calling out, both of which produce subtly broken software if
you miss them:

- **Byte 6 of the status report is battery, not connection.** On the first
  power-on it reads `0x08`, indistinguishable from a connect flag. Only a
  battery swap separates them — it settles to `0x02` on a low cell while the
  real connection bytes stay pinned at `0x08`. Trigger on it and your audio
  starts switching by itself as the battery drains.
- **`b5` is exclusively the connection event.** Volume (`b9`), ANC and
  transparency (`2e`), battery (`b7`) and one unidentified subcommand (`bd`)
  all share report ID 7 and are separable only by byte 1. A capture exercising
  volume, ChatMix, ANC, transparency and EQ produced no `b5` at all.

`tools/probe.swift` is the tool used for this and is included, so the work is
reproducible:

```sh
swiftc -O tools/probe.swift -o build/probe
./build/probe --no-poll     # passive listen, sends the device nothing
```

## Hardware support

Only the Arctis Nova Pro Wireless (`0x1038:0x12E0`) — the one device this was
developed and verified against.

Other Arctis models are deliberately **not** listed. Their USB IDs are public,
but their report formats are not verified here, and shipping untested device
support mostly generates bug reports nobody can reproduce. If you have another
model, `tools/probe.swift` will tell you what it emits; a capture in an issue is
very welcome.

## Uninstalling

```sh
arctis uninstall          # or ./teardown.sh
arctis uninstall --dry    # show what would be removed, change nothing
```

This unloads the LaunchAgent, stops any running daemon, and removes the plist,
the CLI symlink, saved state and logs. It then verifies the removal and exits
non-zero if anything survived.

Everything created outside the project directory is listed in
[`RESOURCES.md`](RESOURCES.md). Deleting the repo alone is **not** a complete
uninstall — the LaunchAgent is a system registration that outlives it.

## Building

```sh
swift build -c release            # -> .build/release/arctis-audioswitch
```

`bin/arctis` prefers the SwiftPM build and falls back to `build/`, which is the
layout the release tarball ships.

Released binaries are built for **arm64 only**, on an Apple Silicon runner.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with SteelSeries.
