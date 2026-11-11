# Scenario: screen lock. Sourced by run.sh (inner part) after lib.sh.
# swaylock is not used: it needs the user's password to unlock, so a test lock
# client (bin/lockclient, tests/e2e/lockclient.c) takes its place. It locks the
# session like any ext-session-lock client and unlocks on SIGUSR1.

scenario_lock() {
  begin lock
  : > "$E2E_LOCKOUT"
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  expect "unlocked at first" '.locked == false'
  local focused count
  focused="$(q 'F.app_id')"
  count="$(q 'n')"

  # lockSession runs the lockCommand.
  key super+Escape
  if ! wait_until 5 grep -q '^locked$' "$E2E_LOCKOUT"; then
    FAILED=1; DETAIL="$DETAIL [lock client never reported locked]"
    kill -USR1 "$(sed -n "s/^pid //p" "$E2E_LOCKOUT")" 2>/dev/null
    return
  fi
  expect "state shows the lock" '.locked == true'

  # Bindings are disabled: no focus change, no new window.
  key super+j
  key super+Return
  key super+p
  sleep 0.5
  expect "focus unchanged while locked" "F.app_id == \"$focused\" and n == $count"
  # A whileLocked binding still works.
  key super+o
  expect "whileLocked binding works" 'cnt("e2e-locked") == 1'

  # Unlock: the bindings come back.
  kill -USR1 "$(sed -n "s/^pid //p" "$E2E_LOCKOUT")"
  expect "unlocked" '.locked == false'
  focused="$(q 'F.app_id')"
  key super+j
  expect "focus changes after unlock" "F.app_id != \"$focused\""
  key super+Return
  expect "bindings work after unlock" 'cnt("e2e-term") == 2'
}
