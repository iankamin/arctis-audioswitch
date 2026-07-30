# Resource Manifest

Every artifact this project creates, inside and outside the repo directory.
**Anything added here must also be handled by `teardown.sh`.**

Run `./teardown.sh` to remove everything listed under "Outside the project
directory". Deleting the project folder alone is NOT sufficient — the
LaunchAgent is a persistent system registration and survives it.

Status legend: `PLANNED` = not yet created, `LIVE` = currently exists.

---

## Outside the project directory

These persist beyond this chat session and beyond deleting the repo.

| Resource | Path / ID | Type | Status |
|---|---|---|---|
| Installed release | `~/.local/share/arctis-audioswitch/` | Directory (extracted v1.0.2 tarball) | **LIVE** |
| CLI symlink | `~/.local/bin/arctis` | Symlink → the above | **LIVE** |
| Persisted state | `~/Library/Application Support/ArctisNovaPro/state.json` | File (remembered fallback device UIDs) | **LIVE** |
| LaunchAgent plist | `~/Library/LaunchAgents/io.github.iankamin.arctis-audioswitch.plist` | File + `launchctl` registration | **LIVE** — created by `arctis enable` |
| LaunchAgent job | `gui/$UID/io.github.iankamin.arctis-audioswitch` | launchd job (bootstrapped) | **LIVE** |

> Do **not** install into `~/Downloads`, `~/Desktop` or `~/Documents`. Those
> are TCC-protected, so a LaunchAgent executing from them raises a
> files-and-folders prompt at login and fails silently if denied. This was hit
> during testing. `~/.local/share` is not protected.
| Log output | `$TMPDIR/arctis-audioswitch/audioswitch.log` | File, **self-clearing** | PLANNED — written only when run under launchd |
| Log output (stderr) | `$TMPDIR/arctis-audioswitch/audioswitch.err.log` | File, **self-clearing** | PLANNED — same |

Logs live in the per-user temp directory (`/var/folders/…/T/`, mode `0700`)
rather than `~/Library/Logs`, so the OS clears them and nothing accumulates
across reboots. `teardown.sh` removes them anyway, plus the legacy
`~/Library/Logs/ArctisNovaPro` path in case an older install left one.

launchd does not expand environment variables in plist paths, so `$TMPDIR` is
resolved by `bin/arctis` and the absolute path is baked in when the plist is
written.

The daemon binary deliberately stays in `build/` inside this project rather
than being copied to `~/.local/bin`, so it is not an external resource.
(This changes if the project is repackaged for distribution.)

### Not created by us — do not touch
- `~/Library/LaunchAgents/com.valvesoftware.steamclean.plist` — pre-existing, Steam's.
- `~/.local/bin/claude` — pre-existing symlink, not ours. `teardown.sh` only
  removes `~/.local/bin/arctis`, and only when it points into this project.

### Published (outside this machine)
- GitHub repo `iankamin/arctis-audioswitch` — **public**, pushed 2026-07-30.
- Release `v1.0.0` with `arctis-audioswitch-1.0.0-macos-arm64.tar.gz`.
  Not removable by `teardown.sh`; delete via
  `gh release delete v1.0.0` and `gh repo delete` if ever needed.
  The published captures contain audio device names (`X34 V`,
  `MacBook Pro Microphone`).

---

## Inside the project directory

Removed by deleting the project folder. `teardown.sh` does not delete these
by default (use `./teardown.sh --all` to also wipe build output).

| Resource | Path | Notes |
|---|---|---|
| Probe source | `tools/probe.swift` | Protocol reverse-engineering tool |
| Probe binary | `build/probe` | Compiled, gitignored |
| Daemon source | `Sources/main.swift` | (planned) |
| Daemon binary | `build/arctis-audioswitch` | Compiled, gitignored |
| Capture logs | `captures/*.log` | Raw HID dumps from probe runs |

---

## Background processes

Long-running processes started during a session. None should outlive the
session except the LaunchAgent.

| Process | How started | How to stop | Status |
|---|---|---|---|
| `build/arctis-audioswitch --verbose` | Started by Claude for the live switching test, logging to `captures/daemon-test.log` | `arctis stop`, or `./teardown.sh` | **LIVE** (pid 99438 as of 2026-07-30 15:04) |
| `build/probe` | Protocol capture, 5 instances | `./teardown.sh` | all stopped 2026-07-30 15:15 |

### Identifying our processes correctly

Five orphaned `probe` processes accumulated during development because
cleanup used `pkill -f 'ArctisNovaPro/build/probe'` while the processes were
started as `./build/probe`. The relative path meant the pattern never
matched, and each "stopped" report was wrong.

**Match the resolved executable, not the command line.** Both `pgrep -f` and
`ps -o comm=` show the path as invoked. `lsof -a -p PID -d txt` gives the real
path:

```sh
lsof -a -p "$pid" -d txt -Fn | grep '^n' | head -1 | cut -c2-
```

`teardown.sh` now uses this, so it kills every instance regardless of how it
was launched, and skips same-named processes belonging to anything else.
Verify with `./teardown.sh --dry` before trusting a cleanup.

> This daemon was started directly, **not** via launchd — nothing is
> registered with `launchctl` and no plist exists. It will not come back
> after a reboot. If this chat session ends while it is running, stop it with
> `pkill -f arctis-audioswitch` (or run `./teardown.sh`).
>
> While running it actively changes your default audio devices on every
> headset power event. That is its purpose, but it is worth knowing if you
> are debugging unexpected audio switching.

---

## System permissions (TCC)

Nothing here yet. The vendor HID usage page (`0xFFC0`) is not a protected
usage page, so **no Input Monitoring grant is required**. Recorded here in
case that changes.

| Permission | Granted to | Revoke via | Status |
|---|---|---|---|
| — | — | — | none |

---

## Verify nothing is orphaned

```sh
launchctl list | grep -i arctis                  # expect: no output
ls ~/Library/LaunchAgents | grep -i arctis       # expect: no output
ls ~/.local/bin/arctis                           # expect: No such file
ls ~/Library/Application\ Support/ArctisNovaPro  # expect: No such file
ls "$TMPDIR/arctis-audioswitch"                  # expect: No such file
pgrep -x arctis-audioswitch                      # expect: no output
```

Or just run `./teardown.sh`, which performs these checks itself and exits
non-zero if anything survived.
