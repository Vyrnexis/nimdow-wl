# Harness helpers for the inner part of run.sh (runs inside the nested river).
# Expects ROOT, OUT, RESULTS, PHASE, ONLY, E2E_RT in the environment/shell.

NIMDOW="$ROOT/bin/nimdow-wl"
INPUT="$ROOT/bin/nimdowinput"
ST="$OUT/state.json"
JQDEFS='def M: .monitors[0]; def C: M.clients; def F: .focused;
  def n: [C[]] | length; def cnt(a): [C[] | select(.app_id == a)] | length;
  def app(a): [C[] | select(.app_id == a)][0];'

# wait_until <timeout seconds> <cmd...>: polls cmd every ~50 ms until it
# succeeds (return 0) or the timeout passes (return 1).
wait_until() {
  local timeout="$1" i n
  shift
  n=$(awk -v t="$timeout" 'BEGIN { printf "%d", t * 20 }')
  for ((i = 0; i < n; i++)); do
    "$@" && return 0
    sleep 0.05
  done
  "$@"
}

# file_is <file> <text>: the file's content equals text exactly.
file_is() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }

dump() {
  rm -f "$ST"
  "$NIMDOW" --dumpState "$ST" >/dev/null 2>&1
  wait_until 2 test -s "$ST"
}

# q <jq-expr>: prints the value from a fresh state dump.
q() { dump; jq -r "$JQDEFS $1" "$ST" 2>/dev/null; }

FAILED=0
DETAIL=""
# expect <description> <jq-boolean-expr>: polls the state for up to ~3s.
expect() {
  local desc="$1" expr="$2" i
  for i in $(seq 1 20); do
    if dump && jq -e "$JQDEFS $expr" "$ST" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.15
  done
  FAILED=1
  DETAIL="$DETAIL [$desc: $expr]"
  cp "$ST" "$OUT/fail-$CURRENT-$(date +%s%N).json" 2>/dev/null
  return 1
}

shot() { grim "$OUT/$1.png" 2>/dev/null; }
key() { "$INPUT" key "$1"; }
spawn() {  # spawn <class> <title> : a client outside of key bindings
  alacritty --class "$1" --title "$2" -e sleep 3600 >/dev/null 2>&1 &
}

CURRENT=""
begin() {
  CURRENT="$1"
  FAILED=0
  DETAIL=""
  echo "--- $1 (river log line $(wc -l < "$OUT/river-$PHASE.log"))"
  reset
}
finish() {
  echo "    done (river log line $(wc -l < "$OUT/river-$PHASE.log"))"
  if [ "$FAILED" = 0 ]; then
    echo "PASS $CURRENT: ok" >> "$RESULTS"
  else
    echo "FAIL $CURRENT:$DETAIL" >> "$RESULTS"
  fi
}

# kill_windows: kills this run's e2e windows only. Their class is fixed by
# config.toml, so they are told apart by the private XDG_RUNTIME_DIR they
# inherited (concurrent runs in other checkouts have their own).
kill_windows() {
  local pid
  for pid in $(pgrep -f 'alacritty --class [e]2e' 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qxF "XDG_RUNTIME_DIR=$E2E_RT"; then
      kill "$pid" 2>/dev/null
    fi
  done
}

# Closes every test window, views tag 1 and re-enables the bar.
reset() {
  kill_windows
  expect "reset: no windows" '[.monitors[].clients[]] | length == 0' >/dev/null
  FAILED=0; DETAIL=""
  if [ "$(q '.monitors[0].selectedTags | tostring')" != "[1]" ]; then
    key super+1
    expect "reset: tag 1" 'M.selectedTags == [1]' >/dev/null
  fi
  if [ "$(q 'M.barVisible')" != "true" ]; then
    key super+b
    expect "reset: bar" 'M.barVisible' >/dev/null
  fi
  FAILED=0; DETAIL=""
}

# term <key>: spawns a window with a key binding and waits for it.
spawn_key() {  # spawn_key <key> <app_id> <expected count>
  key "$1"
  expect "spawn $2" "cnt(\"$2\") == $3 and F.app_id == \"$2\""
}

WIDTH=0; HEIGHT=0; BAR=0

center_of() {  # center_of <app_id> -> "x y" of the window's center
  q "app(\"$1\") | \"\(.x + .width / 2 | floor) \(.y + .height / 2 | floor)\""
}

run() {  # run <scenario function name>
  if [ -n "$ONLY" ] && ! [[ ",$ONLY," == *",${1#scenario_},"* ]]; then
    return
  fi
  "$1"
  finish
}
