# Scenarios: core window-manager behaviour. Sourced by run.sh (inner part) after lib.sh;
# this file only defines scenario functions.

scenario_spawn() {
  begin spawn
  spawn_key super+Return e2e-term 1
  expect "tiled on tag 1, visible, below the bar" \
    'F.tags == [1] and F.visible and (F.floating | not) and F.y >= M.barHeight and F.x >= 0'
  expect "fills the monitor (single window)" \
    "F.width + 2 * F.borderWidth <= $WIDTH and F.reportedWidth == F.width and F.reportedHeight == F.height"
  shot spawn
  spawn_key super+i e2e-browser 1
  spawn_key super+p e2e-launcher 1
  expect "three windows" 'n == 3'
  shot spawn-three
}

scenario_viewTags() {
  begin viewTags
  spawn_key super+Return e2e-term 1
  local n
  for n in 2 3 4 5 6 7 8 9; do
    key "super+$n"
    expect "view tag $n" "M.selectedTags == [$n]"
  done
  expect "window hidden away from tag 1" '(C[0].visible | not)'
  shot viewTags-9
  key super+1
  expect "back on tag 1" 'M.selectedTags == [1] and C[0].visible'
}

scenario_moveToTag() {
  begin moveToTag
  spawn_key super+Return e2e-term 1
  key super+shift+3
  expect "window moved to tag 3, hidden" 'C[0].tags == [3] and (C[0].visible | not) and M.selectedTags == [1]'
  key super+3
  expect "view tag 3 shows it" 'M.selectedTags == [3] and C[0].visible and F.app_id == "e2e-term"'
  key super+shift+5
  expect "moved on to tag 5" 'C[0].tags == [5] and (C[0].visible | not)'
  key super+5
  expect "tag 5" 'C[0].visible'
}

scenario_focus() {
  begin focus
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  spawn_key super+p e2e-launcher 1
  local start next prev
  start="$(q 'F.app_id')"
  key super+j
  expect "focusNext changes focus" "F.app_id != \"$start\""
  next="$(q 'F.app_id')"
  key super+j
  expect "focusNext again" "F.app_id != \"$next\" and F.app_id != \"$start\""
  key super+j
  expect "focusNext wraps around" "F.app_id == \"$start\""
  key super+k
  expect "focusPrevious" "F.app_id != \"$start\""
  prev="$(q 'F.app_id')"
  [ "$prev" = "$next" ] && : # (order is the stack order; only require a change and return)
  key super+j
  expect "back to start" "F.app_id == \"$start\""
  shot focus
}

scenario_masterCount() {
  begin masterCount
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  spawn_key super+p e2e-launcher 1
  local leftcol='([C[] | .x] | min) as $x | [C[] | select(.x == $x)] | length'
  expect "one master" "$leftcol == 1"
  key super+z
  expect "two masters share the left column" "$leftcol == 2"
  shot masterCount-2
  key super+x
  expect "one master again" "$leftcol == 1"
}

scenario_masterWidth() {
  begin masterWidth
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  local masterw
  masterw='([C[] | .x] | min) as $x | [C[] | select(.x == $x)][0].width'
  local w0
  w0="$(q "$masterw")"
  key super+l
  expect "wider master" "$masterw > $w0"
  local w1
  w1="$(q "$masterw")"
  key super+h
  key super+h
  expect "narrower master" "$masterw < $w1"
  shot masterWidth
  key super+l
  expect "restored" "$masterw == $w0"
}

scenario_floating() {
  begin floating
  spawn_key super+Return e2e-term 1
  key super+space
  expect "toggled to floating" 'F.floating'
  shot floating
  key super+space
  expect "toggled back to tiled" '(F.floating | not)'
}

scenario_floatingKeys() {
  begin floatingKeys
  spawn_key super+Return e2e-term 1
  key super+ctrl+l
  expect "move keys do nothing on a tiled window" '(F.floating | not)'
  key super+space
  expect "first float: 50% of the usable area, centered" \
    "F.floating and ((F.width + 2 * F.borderWidth) - $WIDTH / 2 | fabs) <= 2
       and ((F.height + 2 * F.borderWidth) - ($HEIGHT - $BAR) / 2 | fabs) <= 2
       and ((F.x + (F.width + 2 * F.borderWidth) / 2) - $WIDTH / 2 | fabs) <= 2
       and ((F.y + (F.height + 2 * F.borderWidth) / 2) - ($BAR + ($HEIGHT - $BAR) / 2) | fabs) <= 2"
  shot floatingKeys
  local x0 y0 w0 h0
  x0="$(q 'F.x')"; y0="$(q 'F.y')"; w0="$(q 'F.width')"; h0="$(q 'F.height')"
  key super+ctrl+l
  expect "moved right by the step" "F.x == $x0 + 40 and F.y == $y0 and F.width == $w0"
  key super+ctrl+j
  expect "moved down by the step" "F.x == $x0 + 40 and F.y == $y0 + 40"
  key super+ctrl+h
  key super+ctrl+k
  expect "moved back left and up" "F.x == $x0 and F.y == $y0"
  key super+ctrl+shift+l
  expect "wider by the step" "F.width == $w0 + 40 and F.height == $h0 and F.x == $x0"
  key super+ctrl+shift+j
  expect "taller by the step" "F.width == $w0 + 40 and F.height == $h0 + 40"
  key super+ctrl+shift+h
  key super+ctrl+shift+k
  expect "narrower and shorter by the step" "F.width == $w0 and F.height == $h0"
  key super+ctrl+l
  key super+ctrl+shift+l
  expect "moved and widened" "F.x == $x0 + 40 and F.width == $w0 + 40"
  key super+c
  expect "centered again" \
    "((F.x + (F.width + 2 * F.borderWidth) / 2) - $WIDTH / 2 | fabs) <= 2
       and ((F.y + (F.height + 2 * F.borderWidth) / 2) - ($BAR + ($HEIGHT - $BAR) / 2) | fabs) <= 2
       and F.width == $w0 + 40"
  key super+ctrl+j
  local x1 y1 w1 h1
  x1="$(q 'F.x')"; y1="$(q 'F.y')"; w1="$(q 'F.width')"; h1="$(q 'F.height')"
  key super+space
  expect "tiled again" '(F.floating | not)'
  key super+space
  expect "floating again restores the last floating geometry" \
    "F.floating and F.x == $x1 and F.y == $y1 and F.width == $w1 and F.height == $h1"
}

scenario_fullscreen() {
  begin fullscreen
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  key super+f
  expect "fullscreen state" 'F.fullscreen'
  expect "client got the whole output" \
    "F.reportedWidth == $WIDTH and F.reportedHeight == $HEIGHT"
  expect "other windows hidden" '[C[] | select(.visible)] | length == 1'
  shot fullscreen
  key super+f
  expect "left fullscreen" '(F.fullscreen | not) and ([C[] | select(.visible)] | length == 2)'
}

scenario_close() {
  begin close
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  key super+shift+q
  expect "focused window closed" 'n == 1 and F.app_id == "e2e-term"'
  key super+shift+q
  expect "last window closed" 'n == 0 and F == null'
}

scenario_tagOps() {
  begin tagOps
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  key super+ctrl+2
  expect "toggleTagView adds tag 2 to the view" 'M.selectedTags == [1,2]'
  key super+ctrl+2
  expect "toggleTagView removes it again" 'M.selectedTags == [1]'
  key super+Right
  expect "goToRightTag" 'M.selectedTags == [2]'
  key super+Left
  expect "goToLeftTag" 'M.selectedTags == [1]'
  key super+Left
  expect "goToLeftTag wraps to the last tag" 'M.selectedTags == [9]'
  key super+Right
  expect "goToRightTag wraps to the first tag" 'M.selectedTags == [1]'
  key super+3
  expect "tag 3" 'M.selectedTags == [3]'
  key super+w
  expect "goToPreviousTag" 'M.selectedTags == [1]'
  key super+shift+Right
  expect "moveWindowToRightTag moves the focused window to tag 2" \
    'app("e2e-browser").tags == [2] and (app("e2e-browser").visible | not) and F.app_id == "e2e-term"'
  key super+shift+ctrl+3
  expect "toggleWindowTag adds tag 3" 'app("e2e-term").tags == [1,3]'
  key super+shift+ctrl+3
  expect "toggleWindowTag removes tag 3" 'app("e2e-term").tags == [1]'
  key super+shift+Left
  expect "moveWindowToLeftTag wraps to tag 9" 'app("e2e-term").tags == [9]'
  shot tagOps
}

scenario_order() {
  begin order
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  spawn_key super+p e2e-launcher 1
  local before after
  before="$(q '[C[].app_id] | join(",")')"
  key super+r
  after="$(q '[C[].app_id] | join(",")')"
  expect "rotateClients changes the stack order" "([C[].app_id] | join(\",\")) != \"$before\""
  key super+r
  key super+r
  expect "three rotations restore the order" "([C[].app_id] | join(\",\")) == \"$before\""
  local focused
  focused="$(q 'F.app_id')"
  key super+shift+j
  expect "moveWindowNext reorders the stack, focus stays" \
    "([C[].app_id] | join(\",\")) != \"$before\" and F.app_id == \"$focused\""
  key super+shift+k
  expect "moveWindowPrevious restores it" "([C[].app_id] | join(\",\")) == \"$before\""
}

scenario_reload() {
  begin reload
  spawn_key super+Return e2e-term 1
  key super+shift+r
  # Bindings are re-created: they must still work.
  key super+2
  expect "bindings work after reloadConfig" 'M.selectedTags == [2]'
  key super+1
  expect "tag 1" 'M.selectedTags == [1] and F.app_id == "e2e-term"'
}

scenario_typing() {
  begin typing
  local file="$OUT/typed.txt"
  rm -f "$file"
  alacritty --class e2e-type --title e2e-type -e sh -c "cat > '$file'" >/dev/null 2>&1 &
  expect "new window has the keyboard focus" 'F.app_id == "e2e-type"'
  sleep 1
  "$INPUT" type "Hello, World! 42"
  key Return
  key control+d
  if ! wait_until 4 file_is "$file" "Hello, World! 42"; then
    FAILED=1
    DETAIL="$DETAIL [typed text did not arrive: \"$(cat "$file" 2>/dev/null)\"]"
  fi
}

scenario_dragMove() {
  begin dragMove
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  local x0 y0 cx cy
  x0="$(q 'app("e2e-browser").x')"
  y0="$(q 'app("e2e-browser").y')"
  read -r cx cy <<<"$(center_of e2e-browser)"
  "$INPUT" drag super left "$cx" "$cy" $((cx - 60)) $((cy + 70))
  expect "dragged window floats and moved by the drag delta" \
    "app(\"e2e-browser\") | .floating and (.x - ($x0 - 60) | fabs) <= 3 and (.y - ($y0 + 70) | fabs) <= 3"
  shot dragMove
}

scenario_dragResize() {
  begin dragResize
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  local w0 h0 cx cy
  w0="$(q 'app("e2e-browser").width')"
  h0="$(q 'app("e2e-browser").height')"
  read -r cx cy <<<"$(center_of e2e-browser)"
  "$INPUT" drag super right "$cx" "$cy" $((cx - 40)) $((cy - 50))
  expect "resized by the drag delta (bottom-right edges)" \
    "app(\"e2e-browser\") | .floating and (.width - ($w0 - 40) | fabs) <= 3 and (.height - ($h0 - 50) | fabs) <= 3"
  shot dragResize
}

# Bar tag N center: tags are drawn left to right in 24px cells (default font).
bar_tag_x() { echo $((12 + 24 * ($1 - 1))); }

scenario_barClick() {
  begin barClick
  spawn_key super+Return e2e-term 1
  "$INPUT" move "$(bar_tag_x 4)" $((BAR / 2))
  "$INPUT" click left
  expect "bar click on tag 4 views it" 'M.selectedTags == [4]'
  "$INPUT" move "$(bar_tag_x 1)" $((BAR / 2))
  "$INPUT" click left
  expect "bar click on tag 1 views it" 'M.selectedTags == [1]'
  shot barClick
}

scenario_barScroll() {
  begin barScroll
  spawn_key super+Return e2e-term 1
  "$INPUT" move "$(bar_tag_x 4)" $((BAR / 2))
  "$INPUT" scroll down
  expect "scroll down views the next tag" 'M.selectedTags == [2]'
  "$INPUT" scroll down
  expect "scroll down again" 'M.selectedTags == [3]'
  "$INPUT" scroll up
  expect "scroll up views the previous tag" 'M.selectedTags == [2]'
}

scenario_clickFocus() {
  begin clickFocus
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  local cx cy
  read -r cx cy <<<"$(center_of e2e-term)"
  "$INPUT" move "$cx" "$cy"
  "$INPUT" click left
  expect "click focuses the clicked tiled window" 'F.app_id == "e2e-term"'
  read -r cx cy <<<"$(center_of e2e-browser)"
  "$INPUT" move "$cx" "$cy"
  "$INPUT" click left
  expect "click focuses the other window" 'F.app_id == "e2e-browser"'
  shot clickFocus
}

scenario_appRules() {
  begin appRules
  spawn e2e-float e2e-float
  expect "class rule: floating at 100,100 sized 400x300" \
    'app("e2e-float") | .floating and .x == 100 and .y == 100 and .width == 400 and .height == 300'
  spawn e2e-plain e2e-titled
  expect "title rule: moved to tag 4" 'app("e2e-plain") | .tags == [4] and (.visible | not)'
  spawn e2e-center e2e-center
  expect "rule without position: floating and centered in the usable area" \
    "app(\"e2e-center\") | .floating and ((.x + (.width + 2 * .borderWidth) / 2) - $WIDTH / 2 | fabs) <= 2
       and ((.y + (.height + 2 * .borderWidth) / 2) - ($BAR + ($HEIGHT - $BAR) / 2) | fabs) <= 2
       and .y >= $BAR"
  # The title is set (OSC 0) shortly after the window was mapped: the title rule
  # still applies (see applyLateRules in wm/windows.nim).
  alacritty --class e2e-late -e sh -c "sleep 0.3; printf '\\033]0;e2e-late-title\\007'; sleep 3600" \
    >/dev/null 2>&1 &
  expect "late title rule: moved to tag 5" 'app("e2e-late") | .tags == [5]'
  shot appRules
  # Hidden windows are configured once viewed (and can be closed afterwards).
  key super+4
  expect "tag 4 shows the rule's window" 'M.selectedTags == [4] and app("e2e-plain").visible'
  key super+5
  expect "tag 5 shows the late-rule window" 'M.selectedTags == [5] and app("e2e-late").visible'
}

scenario_scratchpad() {
  begin scratchpad
  spawn_key super+Return e2e-term 1
  key super+shift+s
  expect "window hidden in the scratchpad" 'n == 0 and (.scratchpad | length) == 1'
  key super+s
  expect "popped: floating, inside the area below the bar, centered in it" \
    "F.app_id == \"e2e-term\" and F.floating and F.y >= $BAR
       and ((F.x + (F.width + 2 * F.borderWidth) / 2) - $WIDTH / 2 | fabs) <= 2
       and ((F.y + (F.height + 2 * F.borderWidth) / 2) - ($BAR + ($HEIGHT - $BAR) / 2) | fabs) <= 2"
  shot scratchpad
}

scenario_statusBar() {
  begin statusBar
  spawn_key super+Return e2e-term 1
  key super+b
  expect "bar hidden, window uses the whole output" "(M.barVisible | not) and F.y == 0"
  shot statusBar-hidden
  key super+b
  expect "bar back" "M.barVisible and F.y >= $BAR"
}

scenario_exitSession() {
  begin exitSession
  spawn_key super+Return e2e-term 1
  echo "PENDING exitSession" >> "$RESULTS"
  key control+alt+Delete
  sleep 5
}

# Two outputs side by side (WLR_WL_OUTPUTS=2); output 1 is monitors[0].
scenario_multiMonitor() {
  begin multiMonitor
  local M2='.monitors[1]'
  expect "two monitors side by side, each with a bar" \
    "(.monitors | length) == 2 and M.area.x == 0 and $M2.area.x == M.area.width and M.barVisible and $M2.barVisible"
  expect "monitor 1 is selected first" 'M.selected'
  spawn_key super+Return e2e-term 1
  key super+period
  expect "focusNextMonitor selects monitor 2" "$M2.selected and (M.selected | not)"
  key super+i
  expect "new window opens on the selected monitor" \
    "($M2.clients | length) == 1 and $M2.clients[0].app_id == \"e2e-browser\" and $M2.clients[0].x >= $M2.area.x and (M.clients | length) == 1"
  shot multi-two
  key super+shift+comma
  expect "moveWindowToPreviousMonitor moves it to monitor 1 and selects it" \
    "($M2.clients | length) == 0 and (M.clients | length) == 2 and M.selected"
  shot multi-moved
  # The selected monitor follows the pointer.
  local w h
  w="$(q 'M.area.width')"; h="$(q 'M.area.height')"
  "$INPUT" move $((w + w / 2)) $((h / 2))
  expect "pointer on monitor 2 selects it" "$M2.selected"
  "$INPUT" move $((w / 2)) $((h / 2))
  expect "pointer back on monitor 1" "M.selected"
  # Drag a window onto the other monitor.
  local cx cy
  read -r cx cy <<<"$(center_of e2e-browser)"
  "$INPUT" drag super left "$cx" "$cy" $((w + w / 2)) $((h / 2))
  expect "dropped window belongs to monitor 2 and floats" \
    "($M2.clients | length) == 1 and $M2.clients[0].floating and $M2.clients[0].x >= $M2.area.x - 5 and (M.clients | length) == 1"
  shot multi-drag
  # Bar click on monitor 2 only changes monitor 2's tags.
  "$INPUT" move $((w + 12 + 24 * 2)) $((BAR / 2))
  "$INPUT" click left
  expect "bar click on monitor 2 views tag 3 there" "$M2.selectedTags == [3] and M.selectedTags == [1]"
  "$INPUT" move $((w + 12)) $((BAR / 2))
  "$INPUT" click left
  expect "back to tag 1 on monitor 2" "$M2.selectedTags == [1]"
}
