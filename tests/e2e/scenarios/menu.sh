# Scenarios: dbusmenu popups of tray items. Sourced by run.sh (inner part) after
# lib.sh and tray.sh (uses the tray fixtures).

# Menu helpers.
menu_row() {  # menu_row <level> <entry id>: "x y" of the row's center on the screen
  q "[.menu.popups[] | select(.level == $1)][0] as \$p | [\$p.rows[] | select(.id == $2)][0] | \"\(\$p.x + 40) \(.y + (.height / 2 | floor))\""
}
click_row() {  # click_row <level> <entry id>
  local x y
  read -r x y <<<"$(menu_row "$1" "$2")"
  "$INPUT" move "$x" "$y"
  "$INPUT" click left
}
hover_row() {
  local x y
  read -r x y <<<"$(menu_row "$1" "$2")"
  "$INPUT" move "$x" "$y"
}
# menu_open <icon id> [button]: clicks the icon, waits for the popup (and the keyboard focus).
menu_open() {
  "$INPUT" move "$(tray_x "$1")" $((BAR / 2))
  "$INPUT" click "${2:-right}"
  expect "menu open" '.menu.open and .menu.popups[0].mapped and .menu.keyboardFocus'
}
no_log() {  # no_log <pattern> <description>: the pattern must not be in the log
  if grep -q -- "$1" "$SNI_LOG" 2>/dev/null; then
    FAILED=1
    DETAIL="$DETAIL [$2: unexpected '$1' in sni.log]"
  fi
}

scenario_menuOpen() {
  begin menuOpen
  tray_up
  menu_open fake-name
  expect "entries as the fixture exports them (mnemonics stripped)" \
    '[.menu.entries[] | .label] == ["Open", "", "Toggle me", "Disabled", "More", "Quit _now"]'
  expect "entry properties" \
    '(.menu.entries | map(.type) == ["standard","separator","standard","standard","standard","standard"])
     and ([.menu.entries[] | select(.id == 2)][0] | .toggle == "checkmark" and .checked == false)
     and ([.menu.entries[] | select(.id == 8)][0] | .enabled == false)
     and ([.menu.entries[] | select(.id == 3)][0] | .submenu == true)
     and (.menu.submenuOpen | not)'
  expect "popup below the bar, inside the output, at least 150 wide" \
    "M.barHeight as \$bh | .menu.popups[0] | .y == \$bh and .x >= 0 and .x + .width <= $WIDTH and .y + .height <= $HEIGHT and .width >= 150"
  wait_log "fake-name MenuAboutToShow 0" "AboutToShow(0) sent"
  shot menuOpen
  key Escape
  expect "closed" '(.menu.open | not)'
  tray_kill
}

scenario_menuActivate() {
  begin menuActivate
  tray_up
  menu_open fake-name
  click_row 0 1
  wait_log "fake-name MenuEvent 1 clicked" "Open clicked"
  expect "menu closed after the activation" '(.menu.open | not)'
  tray_kill
}

scenario_menuToggle() {
  begin menuToggle
  tray_up
  menu_open fake-name
  click_row 0 2
  wait_log "fake-name MenuEvent 2 clicked" "Toggle me clicked"
  expect "closed" '(.menu.open | not)'
  menu_open fake-name
  expect "checkmark state updated" '[.menu.entries[] | select(.id == 2)][0] | .checked == true'
  shot menuToggle
  key Escape
  tray_kill
}

scenario_menuDisabled() {
  begin menuDisabled
  tray_up
  menu_open fake-name
  click_row 0 8
  sleep 0.7
  no_log "MenuEvent 8" "disabled entry activated"
  expect "menu stays open" '.menu.open'
  # Separators do nothing either.
  click_row 0 7
  sleep 0.4
  no_log "MenuEvent 7" "separator activated"
  expect "still open" '.menu.open'
  key Escape
  tray_kill
}

scenario_menuSubmenu() {
  begin menuSubmenu
  tray_up
  menu_open fake-name
  hover_row 0 3
  expect "hovering More opens the submenu with its two entries" \
    '.menu.submenuOpen and ([.menu.submenuEntries[] | .label] == ["Sub A", "Sub B"]) and .menu.popups[1].mapped'
  # The tray is at the right edge: no room to the right, so the submenu flips to the left.
  expect "submenu next to the parent (flipped left at the screen edge), inside the output" \
    ".menu.popups as \$p | (\$p[1].x + \$p[1].width <= \$p[0].x + 2) and \$p[1].x >= 0 and \$p[1].y >= \$p[0].y and \$p[1].y + \$p[1].height <= $HEIGHT"
  wait_log "fake-name MenuAboutToShow 3" "AboutToShow(submenu)"
  wait_log "fake-name MenuEvent 3 opened" "submenu opened event"
  shot menuSubmenu
  # Moving to another entry of the parent closes it again.
  hover_row 0 1
  expect "submenu closed" '(.menu.submenuOpen | not)'
  wait_log "fake-name MenuEvent 3 closed" "submenu closed event"
  click_row 0 3
  expect "click on More opens it too" '.menu.submenuOpen'
  click_row 1 5
  wait_log "fake-name MenuEvent 5 clicked" "Sub B clicked"
  expect "everything closed" '(.menu.open | not)'
  tray_kill
}

scenario_menuKeyboard() {
  begin menuKeyboard
  tray_up
  menu_open fake-name
  key Down; key Down; key Return
  wait_log "fake-name MenuEvent 2 clicked" "Down Down Enter activates the second selectable entry"
  expect "closed" '(.menu.open | not)'
  menu_open fake-name
  key Down; key Down; key Down
  expect "Down skips the separator and the disabled entry: More is selected" \
    '.menu.popups[0] | .rows[.selected].id == 3'
  key Right
  expect "Right opens the submenu and selects its first entry" \
    '.menu.submenuOpen and (.menu.popups[1] | .rows[.selected].id == 4)'
  key Down
  key Left
  expect "Left closes the submenu" '(.menu.submenuOpen | not) and .menu.open'
  key Right
  key Down
  key Return
  wait_log "fake-name MenuEvent 5 clicked" "Sub B activated from the keyboard"
  expect "closed" '(.menu.open | not)'
  # Up wraps to the last entry; Escape closes without an event.
  menu_open fake-name
  key Up
  expect "Up selects the last entry" '.menu.popups[0] | .rows[.selected].id == 6'
  key Escape
  expect "Escape closes" '(.menu.open | not)'
  no_log "MenuEvent 6" "Quit activated"
  tray_kill
}

scenario_menuDismiss() {
  begin menuDismiss
  tray_up
  spawn_key super+Return e2e-term 1
  menu_open fake-name
  local cx cy
  read -r cx cy <<<"$(center_of e2e-term)"
  "$INPUT" move "$cx" "$cy"; "$INPUT" click left
  expect "a click on a window closes the menu" '(.menu.open | not)'
  menu_open fake-name
  "$INPUT" move $((WIDTH / 3)) $((BAR / 2)); "$INPUT" click left
  expect "a click on the empty bar closes it" '(.menu.open | not)'
  menu_open fake-name
  key super+2
  expect "a tag switch closes it" '(.menu.open | not) and M.selectedTags == [2]'
  key super+1
  expect "tag 1" 'M.selectedTags == [1]'
  menu_open fake-name
  kill -9 "$NAME_PID"
  expect "the item vanishing closes it" '(.menu.open | not) and (M.tray | length) == 1'
  tray_kill
}

scenario_menuReopen() {
  begin menuReopen
  tray_up
  menu_open fake-name
  local first
  first="$(q '.menu.itemUid')"
  "$INPUT" move "$(tray_x fake-pixmap)" $((BAR / 2)); "$INPUT" click right
  expect "another icon's menu replaces it" ".menu.open and .menu.itemUid != $first and .menu.keyboardFocus"
  "$INPUT" move "$(tray_x fake-pixmap)" $((BAR / 2)); "$INPUT" click right
  expect "clicking the same icon again closes it" '(.menu.open | not)'
  "$INPUT" move "$(tray_x fake-pixmap)" $((BAR / 2)); "$INPUT" click left
  wait_log "fake-pixmap Activate " "left click on an item without ItemIsMenu activates it"
  expect "no menu for it" '(.menu.open | not)'
  tray_kill
}

scenario_menuHoverIntent() {
  begin menuHoverIntent
  tray_up
  menu_open fake-name
  local mx my ox oy
  read -r mx my <<<"$(menu_row 0 3)"
  read -r ox oy <<<"$(menu_row 0 1)"
  "$INPUT" move "$mx" "$my"
  sleep 0.05
  "$INPUT" move "$ox" "$oy"
  sleep 0.6
  expect "a short hover over More opens nothing" '(.menu.submenuOpen | not)'
  "$INPUT" move "$mx" "$my"
  expect "staying on More opens the submenu" '.menu.submenuOpen and .menu.popups[1].mapped'
  # Diagonal move: across another row of the parent into the submenu.
  local sx sy
  read -r sx sy <<<"$(menu_row 1 4)"
  "$INPUT" move "$ox" "$oy"
  "$INPUT" move "$sx" "$sy"
  sleep 0.6
  expect "the submenu stays open when the pointer reaches it" '.menu.submenuOpen'
  shot menuHoverIntent
  # Resting on another entry of the parent closes it after the grace.
  "$INPUT" move "$ox" "$oy"
  expect "closed after resting on another entry" '(.menu.submenuOpen | not)'
  key Escape
  expect "closed" '(.menu.open | not)'
  tray_kill
}

scenario_menuKeyRepeat() {
  begin menuKeyRepeat
  tray_up
  menu_open fake-name
  "$INPUT" hold Down 1500
  expect "holding Down repeats the key" '.menu.keyRepeats >= 3'
  expect "a row is selected" '.menu.popups[0].selected >= 0'
  local n
  n="$(q '.menu.keyRepeats')"
  sleep 0.5
  [ "$(q '.menu.keyRepeats')" = "$n" ] || { FAILED=1; DETAIL="$DETAIL [repeat continued after the key release]"; }
  key Escape
  expect "closed" '(.menu.open | not)'
  tray_kill
}

scenario_focusRestore() {
  begin focusRestore
  local file="$OUT/typed-menu.txt"
  rm -f "$file"
  tray_up
  alacritty --class e2e-type --title e2e-type -e sh -c "cat > '$file'" >/dev/null 2>&1 &
  expect "typing window focused" 'F.app_id == "e2e-type"'
  sleep 1
  menu_open fake-name
  # Keys go to the menu, not to the window.
  key Down
  expect "menu has the keys" '.menu.popups[0].selected >= 0'
  key Escape
  expect "menu closed" '(.menu.open | not)'
  expect "the window is still the focused one" 'F.app_id == "e2e-type"'
  sleep 0.5
  "$INPUT" type "focus back"
  key Return
  key control+d
  if ! wait_until 4 file_is "$file" "focus back"; then
    FAILED=1
    DETAIL="$DETAIL [keyboard focus not restored to the window, typed: \"$(cat "$file" 2>/dev/null)\"]"
  fi
  tray_kill
}
