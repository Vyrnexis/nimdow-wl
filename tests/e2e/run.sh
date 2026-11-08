#!/usr/bin/env bash
# End-to-end input tests for nimdow running in a nested River.
#
#   bash tests/e2e/run.sh [-o OUTDIR] [-t TIMEOUT_SECONDS] [-b] [-s SCENARIO[,SCENARIO...]]
#
#   -o  output dir for screenshots, logs and results (default: $E2E_OUT or ./e2e-out)
#   -t  overall timeout of the nested river (default 240)
#   -b  build bin/nimdow-wl and bin/nimdowinput first
#   -s  only run the named scenarios (comma separated, see `scenario_*` below)
#
# Requires: river >= 0.5, grim, alacritty, jq, dbus-run-session, python3 with
# gi (for tests/e2e/fake_sni.py), a running Wayland session to nest in.
# nimdow is driven with tests/e2e/config.toml; input is injected with
# bin/nimdowinput (virtual keyboard/pointer). State is asserted through
# `nimdow-wl --dumpState`, with screenshots (grim) as extra evidence.
#
# The nested river runs inside `dbus-run-session`: the tray tests use a private
# session bus and never touch the real one (the inner part aborts if the bus
# address is the outer one).
#
# The script runs twice: the outer part starts river, whose -c command is this
# script again with --inner (it then runs inside the nested session).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="$ROOT/tests/e2e/run.sh"

if [ "${1:-}" = "--inner" ]; then
  MODE=inner
  shift
else
  MODE=outer
fi

OUT="${E2E_OUT:-$ROOT/e2e-out}"
TIMEOUT=240
BUILD=0
ONLY=""
while getopts "o:t:bs:" opt; do
  case $opt in
    o) OUT="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    b) BUILD=1 ;;
    s) ONLY="$OPTARG" ;;
    *) exit 2 ;;
  esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
RESULTS="$OUT/results.txt"

# ---------------------------------------------------------------------------
# Outer: start river
# ---------------------------------------------------------------------------
if [ "$MODE" = outer ]; then
  export PATH="$HOME/.nimble/bin:$PATH"
  for tool in river grim alacritty jq dbus-run-session python3; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 2; }
  done
  if [ "$BUILD" = 1 ] || [ ! -x "$ROOT/bin/nimdow-wl" ] || [ ! -x "$ROOT/bin/nimdowinput" ]; then
    (cd "$ROOT" &&
      nim c --hints:off -o:bin/nimdow-wl --deepcopy:on src/nimdow.nim &&
      nim c --hints:off -o:bin/nimdowinput tests/e2e/nimdowinput.nim) || exit 2
  fi

  rm -f "$OUT"/*.png "$OUT"/*.log "$OUT"/*.json "$OUT"/typed.txt "$RESULTS"
  : > "$RESULTS"
  # Unix socket paths are short: nimdow's IPC socket lives in a private runtime dir.
  RT="$(mktemp -d /tmp/nde2e.XXXXXX)"
  chmod 700 "$RT"
  export E2E_RT="$RT" E2E_OUT="$OUT" E2E_ONLY="$ONLY" E2E_OUTER_BUS="${DBUS_SESSION_BUS_ADDRESS:-none}"

  # run_phase <name> <number of nested outputs> <scenario names...>
  # Phases: "multi" (two outputs) and "single" (one output, ends with exitSession).
  run_phase() {
    local phase="$1" outputs="$2" scenarios=" ${*:3} " s want=0
    if [ -z "$ONLY" ]; then
      want=1
    else
      for s in ${ONLY//,/ }; do
        [[ "$scenarios" == *" $s "* ]] && want=1
      done
    fi
    [ "$want" = 1 ] || return 0
    export E2E_PHASE="$phase"
    local start=$SECONDS
    WLR_WL_OUTPUTS="$outputs" timeout -k 5 "$TIMEOUT" dbus-run-session -- river -no-xwayland \
      -log-level "${E2E_RIVER_LOG:-warning}" \
      -c "bash '$SELF' --inner > '$OUT/inner-$phase.log' 2>&1" > "$OUT/river-$phase.log" 2>&1
    local river_status=$?
    local elapsed=$((SECONDS - start))

    # exitSession (last scenario of the single phase): river must exit by itself.
    if grep -q '^PENDING exitSession' "$RESULTS"; then
      sed -i '/^PENDING exitSession/d' "$RESULTS"
      if [ "$river_status" = 124 ] || [ "$river_status" = 137 ]; then
        echo "FAIL exitSession: river was still running after ${TIMEOUT}s" >> "$RESULTS"
      elif ! grep -q "Starting nimdow-wl" "$OUT/nimdow-wl-$phase.log" 2>/dev/null; then
        echo "FAIL exitSession: nimdow log missing" >> "$RESULTS"
      else
        echo "PASS exitSession: river exited (status $river_status) after ${elapsed}s" >> "$RESULTS"
      fi
    fi

    # River/Wayland protocol errors and nimdow crashes.
    # (The wlroots wayland backend prints "Io error: Broken pipe" when the outer
    # window goes away at shutdown; that is not a nimdow problem.)
    # River's "timeout occurred, some imperfect frames may be shown" means a client
    # (alacritty resizing its GL surface) was slower than River's configure
    # timeout. That is client latency, not a protocol error: counted as a note.
    local bad_river timeouts bad_nimdow
    bad_river=$(grep -E '^(error|warning)|^[A-Za-z]*Error|Segmentation|protocol error|wl_display' \
      "$OUT/river-$phase.log" | grep -viE 'Broken pipe|ExitFailure|timeout occurred' || true)
    timeouts=$(grep -c 'timeout occurred' "$OUT/river-$phase.log")
    [ "$timeouts" -gt 0 ] && echo "NOTE riverTimeouts-$phase: $timeouts slow-client configure timeouts (not protocol errors)" >> "$RESULTS"
    if [ -n "$bad_river" ]; then
      echo "FAIL riverLog-$phase: $(echo "$bad_river" | head -3 | tr '\n' '|')" >> "$RESULTS"
    else
      echo "PASS riverLog-$phase: no protocol errors" >> "$RESULTS"
    fi
    # (nimdow's log also holds the output of spawned alacritty clients, which
    # complain when river goes away.)
    bad_nimdow=$(grep -E 'ERROR|Error:|SIGSEGV|unhandled exception|Traceback|Segmentation' \
      "$OUT/nimdow-wl-$phase.log" 2>/dev/null | grep -viE 'Broken pipe|ExitFailure' || true)
    if [ -n "$bad_nimdow" ]; then
      echo "FAIL nimdowLog-$phase: $(echo "$bad_nimdow" | head -3 | tr '\n' '|')" >> "$RESULTS"
    else
      echo "PASS nimdowLog-$phase: no errors" >> "$RESULTS"
    fi
  }

  run_phase multi 2 multiMonitor
  run_phase trayhost 1 trayHostOnly
  run_phase single 1 spawn viewTags moveToTag focus masterCount masterWidth floating \
    fullscreen close tagOps order reload typing dragMove dragResize barClick barScroll \
    clickFocus appRules scratchpad statusBar trayIcons trayClick trayUpdate trayVanish \
    menuOpen menuActivate menuToggle menuDisabled menuSubmenu menuKeyboard menuDismiss menuReopen \
    trayTooltip menuHoverIntent menuKeyRepeat itemIsMenu trayNoMenu focusRestore exitSession
  rm -rf "$RT"

  echo
  echo "=== e2e results ($OUT) ==="
  cat "$RESULTS"
  fails=$(grep -c '^FAIL' "$RESULTS")
  passes=$(grep -c '^PASS' "$RESULTS")
  echo "passed: $passes  failed: $fails"
  [ "$fails" = 0 ] && [ "$passes" -gt 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# Inner: runs inside the nested river
# ---------------------------------------------------------------------------
cd "$ROOT" || exit 1
# Never run against the user's real session bus.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ "$DBUS_SESSION_BUS_ADDRESS" = "${E2E_OUTER_BUS:-none}" ]; then
  echo "FAIL dbus-$E2E_PHASE: not inside a private session bus, refusing to run" >> "$E2E_OUT/results.txt"
  exit 1
fi
ONLY="${E2E_ONLY:-}"
# River sets a relative WAYLAND_DISPLAY; nimdow gets a private runtime dir for its IPC socket.
export WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
export XDG_RUNTIME_DIR="$E2E_RT"
# Never touch the real systemd user session (env export, autostart target).
export NIMDOW_NO_SESSION=1
# Harness helpers and scenario definitions (functions only; run order is below).
E2E_DIR="$ROOT/tests/e2e"
# shellcheck source=tests/e2e/lib.sh
. "$E2E_DIR/lib.sh"
for f in core tray menu; do
  # shellcheck source=/dev/null
  . "$E2E_DIR/scenarios/$f.sh"
done

# ---------------------------------------------------------------------------

PHASE="${E2E_PHASE:-single}"
if [ "$PHASE" = trayhost ]; then
  # Another StatusNotifierWatcher, and an item registered with it, before nimdow starts.
  : > "$SNI_LOG"
  python3 "$FAKE" watcher --log "$SNI_LOG" > "$OUT/fake-watcher.out" 2>&1 &
  WATCHER_PID=$!
  wait_until 5 grep -q READY "$OUT/fake-watcher.out"
  tray_item name fake-name
  wait_until 5 grep -q "watcher RegisterStatusNotifierItem" "$SNI_LOG"
fi
"$NIMDOW" --config "$ROOT/tests/e2e/config.toml" > "$OUT/nimdow-wl-$PHASE.log" 2>&1 &
NIMDOW_PID=$!
EXPECTED_MONITORS=1
[ "$PHASE" = multi ] && EXPECTED_MONITORS=2
wait_until 10 dump
if ! expect "nimdow started with $EXPECTED_MONITORS monitor(s)" "[.monitors[]] | length == $EXPECTED_MONITORS"; then
  echo "FAIL startup-$PHASE: nimdow did not come up: $DETAIL" >> "$RESULTS"
  exit 1
fi
WIDTH="$(q 'M.area.width')"
HEIGHT="$(q 'M.area.height')"
BAR="$(q 'M.barHeight')"
# Absolute pointer motion is mapped over the bounding box of all outputs.
export NIMDOWINPUT_EXTENT="$(q '"\([.monitors[] | .area.x + .area.width] | max)x\([.monitors[] | .area.y + .area.height] | max)"')"
echo "phase $PHASE: output ${WIDTH}x${HEIGHT}, bar $BAR, pointer extent $NIMDOWINPUT_EXTENT"
shot start

if [ "$PHASE" = multi ]; then
  run scenario_multiMonitor
elif [ "$PHASE" = trayhost ]; then
  run scenario_trayHostOnly
else
  for s in spawn viewTags moveToTag focus masterCount masterWidth floating fullscreen close \
           tagOps order reload typing dragMove dragResize barClick barScroll clickFocus \
           appRules scratchpad statusBar trayIcons trayClick trayUpdate trayVanish \
           menuOpen menuActivate menuToggle menuDisabled menuSubmenu menuKeyboard menuDismiss \
           menuReopen trayTooltip menuHoverIntent menuKeyRepeat itemIsMenu trayNoMenu focusRestore; do
    run "scenario_$s"
  done
  reset
  if [ -z "$ONLY" ] || [[ ",$ONLY," == *",exitSession,"* ]]; then
    scenario_exitSession
  fi
fi
tray_kill
[ -n "${WATCHER_PID:-}" ] && kill "$WATCHER_PID" 2>/dev/null
# Reached when exitSession did not run (or did not end the session).
"$NIMDOW" --exitSession >/dev/null 2>&1
sleep 2
kill "$NIMDOW_PID" 2>/dev/null
