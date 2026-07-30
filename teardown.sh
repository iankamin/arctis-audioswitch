#!/bin/bash
# Removes every resource this project creates outside the project directory.
# See RESOURCES.md for the manifest this mirrors.
#
#   ./teardown.sh          remove external resources, keep build output
#   ./teardown.sh --all    also remove local build/ and captures/
#   ./teardown.sh --dry    show what would be removed, change nothing

set -uo pipefail

LABEL="io.github.iankamin.arctis-audioswitch"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
STATE_DIR="$HOME/Library/Application Support/ArctisNovaPro"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Must match bin/arctis. Temp logs clear themselves on reboot, but remove them
# anyway so an uninstall leaves nothing behind right now.
LOG_DIR="${TMPDIR:-/tmp}"
LOG_DIR="${LOG_DIR%/}/arctis-audioswitch"
# Older versions logged here; clean it up if a previous install left it.
LEGACY_LOG_DIR="$HOME/Library/Logs/ArctisNovaPro"

# CLI symlink created by `arctis install`. Honour the same override.
PREFIX="${ARCTIS_PREFIX:-$HOME/.local/bin}"
CLI_LINK="$PREFIX/arctis"

DRY=0
ALL=0
for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run) DRY=1 ;;
    --all) ALL=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "$@"; }
run() {
  if [ "$DRY" = "1" ]; then
    say "  [dry] $*"
  else
    "$@"
  fi
}

remove_path() {
  local p="$1"
  if [ -e "$p" ]; then
    say "  removing: $p"
    run rm -rf "$p"
  else
    say "  absent:   $p"
  fi
}

say "=== Arctis Nova Pro audio switcher teardown ==="
[ "$DRY" = "1" ] && say "(dry run - nothing will be changed)"
say ""

# 1. Stop and unregister the LaunchAgent.
say "LaunchAgent:"
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
  say "  booting out: gui/$(id -u)/$LABEL"
  run launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
    || run launchctl unload "$PLIST" 2>/dev/null
else
  say "  not loaded"
fi
remove_path "$PLIST"
say ""

# 2. Kill any straggler processes (probe or daemon run by hand).
#
# Identify by RESOLVED EXECUTABLE PATH, not by command line or `ps -o comm=`.
# A process started as `./build/probe` reports that relative path in both, so
# matching on "$PROJECT_DIR/..." silently misses it - which is exactly how
# five orphaned probes accumulated during development. lsof -d txt gives the
# real path regardless of how the process was invoked.
# `-d txt` lists the executable AND every memory-mapped library (dyld, ICU
# data, IOHIDLib...), so do not assume the binary is the first row. We know
# the exact path we are looking for, so test for its presence instead of
# relying on lsof's ordering.
process_uses_binary() {
  local pid="$1" want="$2"
  lsof -a -p "$pid" -d txt -Fn 2>/dev/null | grep '^n' | cut -c2- \
    | grep -qxF "$want"
}

# A binary may live in .build/release (SwiftPM) or build/ (plain swiftc), and
# an old process may still be running the other one.
candidate_paths() {
  case "$1" in
    arctis-audioswitch)
      echo "$PROJECT_DIR/.build/release/arctis-audioswitch"
      echo "$PROJECT_DIR/build/arctis-audioswitch"
      ;;
    probe)
      echo "$PROJECT_DIR/build/probe"
      ;;
  esac
}

say "Processes:"
found_procs=0
for name in arctis-audioswitch probe; do
  for p in $(pgrep -x "$name" 2>/dev/null); do
    matched=""
    while IFS= read -r want; do
      [ -z "$want" ] && continue
      if process_uses_binary "$p" "$want"; then matched="$want"; break; fi
    done <<EOF
$(candidate_paths "$name")
EOF
    if [ -n "$matched" ]; then
      say "  killing $name pid $p ($matched)"
      run kill "$p" 2>/dev/null
      found_procs=1
    else
      say "  skipping pid $p ($name) - not from this project"
    fi
  done
done

# Give them a moment, then escalate anything that ignored SIGTERM.
if [ "$found_procs" = "1" ] && [ "$DRY" = "0" ]; then
  sleep 0.5
  for name in arctis-audioswitch probe; do
    for p in $(pgrep -x "$name" 2>/dev/null); do
      while IFS= read -r want; do
        [ -z "$want" ] && continue
        if process_uses_binary "$p" "$want"; then
          say "  pid $p did not exit, sending SIGKILL"
          kill -9 "$p" 2>/dev/null
          break
        fi
      done <<EOF
$(candidate_paths "$name")
EOF
    done
  done
fi

[ "$found_procs" = "0" ] && say "  none running"
say ""

# 3. CLI symlink, state, logs.
say "Files:"
# Only remove the symlink if it actually points into this checkout - never
# clobber an unrelated binary that happens to share the name.
if [ -L "$CLI_LINK" ]; then
  link_target="$(readlink "$CLI_LINK")"
  case "$link_target" in
    "$PROJECT_DIR"/*)
      say "  removing: $CLI_LINK -> $link_target"
      run rm -f "$CLI_LINK"
      ;;
    *)
      say "  SKIPPING: $CLI_LINK points outside this project ($link_target)"
      ;;
  esac
elif [ -e "$CLI_LINK" ]; then
  say "  SKIPPING: $CLI_LINK exists but is not a symlink - not ours, leaving it"
else
  say "  absent:   $CLI_LINK"
fi
remove_path "$STATE_DIR"
remove_path "$LOG_DIR"
remove_path "$LEGACY_LOG_DIR"
say ""

# 4. Optionally local build output.
if [ "$ALL" = "1" ]; then
  say "Local build output (--all):"
  remove_path "$PROJECT_DIR/build"
  remove_path "$PROJECT_DIR/captures"
  say ""
fi

# 5. Verify.
say "=== Verification ==="
leftover=0
check_gone() {
  local desc="$1"; shift
  local out
  out="$("$@" 2>/dev/null)"
  if [ -n "$out" ]; then
    say "  STILL PRESENT: $desc"
    say "$out" | sed 's/^/      /'
    leftover=1
  else
    say "  clean: $desc"
  fi
}

check_gone "launchctl job"      bash -c "launchctl list 2>/dev/null | grep -i arctis"
check_gone "LaunchAgent plist"  bash -c "ls $HOME/Library/LaunchAgents 2>/dev/null | grep -i arctis"
check_gone "CLI symlink"        bash -c "[ -L '$CLI_LINK' ] && readlink '$CLI_LINK' | grep -F '$PROJECT_DIR'"
check_gone "state dir"          bash -c "ls -d '$STATE_DIR' 2>/dev/null"
check_gone "log dir"            bash -c "ls -d '$LOG_DIR' 2>/dev/null"
check_gone "legacy log dir"     bash -c "ls -d '$LEGACY_LOG_DIR' 2>/dev/null"
check_gone "running processes"  bash -c "pgrep -xl 'arctis-audioswitch' 2>/dev/null"

say ""
if [ "$DRY" = "1" ]; then
  say "Dry run complete."
elif [ "$leftover" = "0" ]; then
  say "All external resources removed."
  say ""
  # Name the directory explicitly. "Delete the project folder" is not
  # actionable for someone who unpacked a release months ago and no longer
  # remembers where it went.
  say "The program itself is still on disk at:"
  say "  $PROJECT_DIR"
  say ""
  say "Delete that folder to finish removing it:"
  say "  rm -rf \"$PROJECT_DIR\""
else
  say "Some resources remain - see above."
  exit 1
fi
