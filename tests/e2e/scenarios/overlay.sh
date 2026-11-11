# Scenario: the hotkey overlay. Sourced by run.sh (inner part) after lib.sh.

scenario_overlay() {
  begin overlay
  spawn_key super+Return e2e-term 1
  expect "closed at first" '.overlayVisible == false'
  key super+slash
  expect "super+slash opens the overlay" '.overlayVisible == true'
  sleep 0.5
  shot overlay
  # Escape closes it (it is a binding that only exists while the overlay is open).
  key Escape
  expect "Escape closes the overlay" '.overlayVisible == false'
  # The toggle key closes it too.
  key super+slash
  expect "reopened" '.overlayVisible == true'
  key super+slash
  expect "super+slash closes the overlay" '.overlayVisible == false'
  # A click on the overlay closes it (it is centred on the output).
  key super+slash
  expect "reopened for the click" '.overlayVisible == true'
  sleep 0.5
  "$INPUT" move "$((WIDTH / 2))" "$((HEIGHT / 2))"; "$INPUT" click left
  expect "a click closes the overlay" '.overlayVisible == false'
}
