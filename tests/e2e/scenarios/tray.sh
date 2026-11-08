# Scenarios: system tray (StatusNotifierItem) and its fixtures. Sourced by run.sh
# (inner part) after lib.sh. Fixtures: tests/e2e/fake_sni.py on the private session bus.

# --- System tray (StatusNotifierItem) -------------------------------------
# Fixtures: tests/e2e/fake_sni.py on the private session bus.
FAKE="$ROOT/tests/e2e/fake_sni.py"
SNI_LOG="$OUT/sni-${E2E_PHASE:-single}.log"
TRAY_PIDS=()
tray_kill() {
  local p
  for p in "${TRAY_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  TRAY_PIDS=()
}
# tray_item <variant> <id> [extra fake_sni.py args]: starts a fake item; its pid is in LAST_PID.
tray_item() {
  python3 "$FAKE" item --variant "$1" --id "$2" --log "$SNI_LOG" "${@:3}" >> "$OUT/fake-$2.out" 2>&1 &
  LAST_PID=$!
  TRAY_PIDS+=("$LAST_PID")
}
# tray_up: fresh fixtures (a named icon, then a pixmap icon), both shown.
tray_up() {
  tray_kill
  : > "$SNI_LOG"
  tray_item name fake-name; NAME_PID=$LAST_PID
  expect "first tray icon" '(M.tray | length) == 1'
  tray_item pixmap fake-pixmap; PIX_PID=$LAST_PID
  expect "both tray icons" '(M.tray | length) == 2'
}
tray_x() { q "[M.tray[] | select(.id == \"$1\")][0] | .x + (.width / 2 | floor)"; }
wait_log() {  # wait_log <pattern> <description>
  wait_until 4.5 grep -q -- "$1" "$SNI_LOG" && return 0
  FAILED=1
  DETAIL="$DETAIL [$2: no '$1' in sni.log]"
  return 1
}

scenario_trayIcons() {
  begin trayIcons
  tray_up
  expect "icons are real, active, inside the bar and do not overlap" \
    "M.barHeight as \$bh | all(M.tray[]; .hasIcon and .status == \"isActive\" and .width == (\$bh - 4) and .x >= 0) and (M.tray[1].x >= M.tray[0].x + M.tray[0].width + 4)"
  expect "named icon found through the theme chain, pixmap converted" \
    '(M.tray[0].icon | test("dialog-information")) and (M.tray[1].icon | startswith("pixmap:32x32"))'
  nimdow_status="tray status text"
  "$NIMDOW" --status "$nimdow_status" >/dev/null 2>&1
  sleep 0.5
  shot trayIcons
  "$NIMDOW" --status "" >/dev/null 2>&1
  tray_kill
}

scenario_trayClick() {
  begin trayClick
  tray_up
  local nx px y=$((BAR / 2))
  nx="$(tray_x fake-name)"; px="$(tray_x fake-pixmap)"
  "$INPUT" move "$nx" "$y"; "$INPUT" click left
  wait_log "fake-name Activate " "left click activates"
  "$INPUT" click middle
  wait_log "fake-name SecondaryActivate " "middle click"
  # A right click opens the dbusmenu popup (the item has a Menu): not ContextMenu.
  "$INPUT" click right
  expect "right click opens the menu popup" '.menu.open and .menu.popups[0].mapped'
  key Escape
  expect "Escape closes it" '(.menu.open | not)'
  grep -q "fake-name ContextMenu " "$SNI_LOG" && {
    FAILED=1; DETAIL="$DETAIL [ContextMenu was called although the item has a menu]"; }
  "$INPUT" scroll down
  wait_log "fake-name Scroll 1 vertical" "scroll down"
  "$INPUT" scroll up
  wait_log "fake-name Scroll -1 vertical" "scroll up"
  "$INPUT" move "$px" "$y"; "$INPUT" click left
  wait_log "fake-pixmap Activate " "click on the second icon"
  # A click on a tray icon does not click a bar tag.
  expect "tags untouched" 'M.selectedTags == [1]'
  tray_kill
}

scenario_trayTooltip() {
  begin trayTooltip
  tray_up
  local nx y=$((BAR / 2))
  nx="$(tray_x fake-name)"
  "$INPUT" move "$nx" "$y"
  sleep 0.1
  expect "no tooltip right after entering the icon" '(.menu.tooltip.visible | not)'
  sleep 0.8
  expect "tooltip with the ToolTip title after the delay" '.menu.tooltip.visible and .menu.tooltip.text == "fake-name tip"'
  expect "tooltip below the bar, inside the output" \
    "M.barHeight as \$bh | .menu.tooltip | .y == \$bh and .x >= 0 and .x + .width <= $WIDTH and .width > 20"
  shot trayTooltip
  "$INPUT" move $((WIDTH / 3)) "$y"
  expect "hidden when the pointer leaves the icon" '(.menu.tooltip.visible | not)'
  "$INPUT" move "$nx" "$y"
  sleep 0.9
  expect "shown again" '.menu.tooltip.visible'
  "$INPUT" click left
  expect "hidden by a click" '(.menu.tooltip.visible | not)'
  sleep 0.9
  expect "not shown again until the pointer re-enters" '(.menu.tooltip.visible | not)'
  "$INPUT" move "$nx" "$y"
  sleep 0.9
  "$INPUT" click right
  expect "menu open hides it" '.menu.open and (.menu.tooltip.visible | not)'
  key Escape
  expect "closed" '(.menu.open | not)'
  tray_kill
}

scenario_itemIsMenu() {
  begin itemIsMenu
  tray_kill
  : > "$SNI_LOG"
  tray_item name fake-ism --item-is-menu
  expect "icon" '(M.tray | length) == 1'
  menu_open fake-ism left
  expect "left click opened the menu" '.menu.open and (.menu.entries | length) == 6'
  no_log "fake-ism Activate" "Activate called"
  key Escape
  expect "closed" '(.menu.open | not)'
  tray_kill
}

scenario_trayNoMenu() {
  begin trayNoMenu
  tray_kill
  : > "$SNI_LOG"
  tray_item name fake-plain --no-menu
  tray_item pixmap fake-ism --no-menu --item-is-menu
  expect "icons" '(M.tray | length) == 2'
  local px
  px="$(tray_x fake-plain)"
  "$INPUT" move "$px" $((BAR / 2)); "$INPUT" click right
  wait_log "fake-plain ContextMenu " "right click without Menu calls ContextMenu"
  "$INPUT" move "$(tray_x fake-ism)" $((BAR / 2)); "$INPUT" click left
  wait_log "fake-ism ContextMenu " "left click on a menu-only item without Menu calls ContextMenu"
  expect "no popup" '(.menu.open | not)'
  tray_kill
}

scenario_trayUpdate() {
  begin trayUpdate
  tray_up
  expect "initial icons" '(M.tray[0].icon | test("dialog-information")) and (M.tray[1].icon | test("pixmap:32x32:FF0000"))'
  kill -USR1 "$NAME_PID" "$PIX_PID"
  expect "NewIcon: named icon changed to the svg, pixmap to green|yellow" \
    '(M.tray[0].icon | test("audio-headphones.svg")) and (M.tray[1].icon | test("pixmap:32x32:00C800")) and all(M.tray[]; .hasIcon)'
  shot trayUpdate
  kill -USR2 "$PIX_PID"
  expect "Passive hides the item" '(M.tray | length) == 1 and M.tray[0].id == "fake-name"'
  kill -USR2 "$PIX_PID"
  expect "Active shows it again" '(M.tray | length) == 2'
  tray_kill
}

scenario_trayVanish() {
  begin trayVanish
  tray_up
  kill -9 "$NAME_PID"
  expect "icon removed when its owner disappears" '(M.tray | length) == 1 and M.tray[0].id == "fake-pixmap"'
  tray_kill
  expect "all icons gone" '(M.tray | length) == 0'
}

# nimdow starts with another watcher already on the bus (phase trayhost).
scenario_trayHostOnly() {
  begin trayHostOnly
  expect "item registered before nimdow started is shown (watcher's list)" \
    '(M.tray | length) >= 1 and M.tray[0].id == "fake-name" and M.tray[0].hasIcon'
  grep -q "another StatusNotifierWatcher exists" "$OUT/nimdow-wl-$PHASE.log" || {
    FAILED=1; DETAIL="$DETAIL [nimdow did not report host-only mode]"; }
  wait_log "watcher RegisterStatusNotifierHost org.kde.StatusNotifierHost-" "nimdow registered its host"
  tray_item pixmap fake-pixmap; PIX_PID=$LAST_PID
  expect "item registered later (watcher signal) is shown" '(M.tray | length) == 2 and all(M.tray[]; .hasIcon)'
  [ "$(grep -c 'watcher RegisterStatusNotifierItem' "$SNI_LOG")" -ge 2 ] || {
    FAILED=1; DETAIL="$DETAIL [items were not registered with the other watcher]"; }
  shot trayHostOnly
  local nx
  nx="$(tray_x fake-name)"
  "$INPUT" move "$nx" $((BAR / 2)); "$INPUT" click left
  wait_log "fake-name Activate " "click in host-only mode"
  # The other watcher goes away: nimdow takes the name over and serves new items.
  kill "$WATCHER_PID"
  sleep 1
  tray_item name fake-late
  expect "a new item registers with nimdow's own watcher" '[M.tray[] | select(.id == "fake-late")] | length == 1'
  tray_kill
}
