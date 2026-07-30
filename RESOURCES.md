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
| Persisted state | `~/Library/Application Support/ArctisNovaPro/state.json` | File (remembered fallback device UIDs, daemon-owned) | **LIVE** |
| User settings | `~/Library/Application Support/ArctisNovaPro/settings.json` | File (banner preference) | **LIVE** |
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

The daemon binary lives inside whichever directory the release was unpacked
into, and the LaunchAgent points at it there. `arctis install` symlinks rather
than copies, so there is no second copy to go stale.

### Not created by us — do not touch
- `~/Library/LaunchAgents/com.valvesoftware.steamclean.plist` — pre-existing, Steam's.
- `~/.local/bin/claude` — pre-existing symlink, not ours. `teardown.sh` only
  removes `~/.local/bin/arctis`, and only when it points into this project.

### Published (outside this machine)
- GitHub repo `iankamin/arctis-audioswitch` — **public**, pushed 2026-07-30.
- Releases `v1.0.0` … `v1.2.0`, each with a tarball and `.sha256`.
  Not removable by `teardown.sh`; delete with `gh release delete <tag>` and
  `gh repo delete` if ever needed.
  The published captures contain audio device names (`X34 V`,
  `MacBook Pro Microphone`).

---

## Inside the project directory

Removed by deleting the project folder.

| Resource | Path | Notes |
|---|---|---|
| Daemon source | `Sources/ArctisAudioSwitch/*.swift` | Tracked |
| Probe source | `tools/probe.swift` | Protocol reverse-engineering tool, tracked |
| Capture logs | `captures/*.log` | Raw HID dumps, tracked as protocol provenance |
| Build output | `build/`, `.build/` | Gitignored, regenerate with `swift build -c release` |

Build output is not currently present — it was removed after release, and
`.build/` alone was ~129 MB.

---

## Background processes

Long-running processes started during a session. None should outlive the
session except the LaunchAgent.

| Process | How started | How to stop | Status |
|---|---|---|---|
| `arctis-audioswitch` | LaunchAgent, from the installed release | `arctis stop` / `arctis disable` | **LIVE** under launchd |
| `build/probe` | Protocol capture during development | `./teardown.sh` | none running |

### Identifying our processes correctly

Five orphaned `probe` processes accumulated during development because
cleanup used `pkill -f 'ArctisNovaPro/build/probe'` while the processes were
started as `./build/probe`. The relative path meant the pattern never
matched, and each "stopped" report was wrong.

**Match the resolved executable, not the command line.** Both `pgrep -f` and
`ps -o comm=` show the path as invoked. `lsof -a -p PID -d txt` gives the real
path:

```sh
lsof -a -p "$pid" -d txt -Fn | grep '^n' | cut -c2- | grep -qxF "$expected"
```

`-d txt` lists the executable *and* every memory-mapped library, so test for
the expected path rather than assuming the binary is the first row.

`teardown.sh` uses this, so it kills every instance regardless of how it was
launched, and skips same-named processes belonging to anything else. Verify
with `./teardown.sh --dry` before trusting a cleanup.

### Uninstalling the right copy

Run `arctis uninstall`, not the project checkout's `teardown.sh`. Each
`teardown.sh` scopes process and symlink removal to *its own* directory, so
the checkout's copy will decline to remove a symlink owned by an installed
release — while still removing the shared `Application Support` and log
directories, since both use the same label. `arctis uninstall` runs the
installed copy's teardown, which owns all of it.

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
