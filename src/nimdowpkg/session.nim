import
  std/[os, osproc]

import logger

## Desktop-session integration, done once at startup (the job niri or sway do
## through their session scripts):
## - export the display variables to the systemd user manager and the D-Bus
##   activation environment, so D-Bus-activated programs (xdg-desktop-portal-gtk,
##   "Open with" from file managers, ...) can reach the display;
## - start `nimdow-wl-session.target`, which binds `graphical-session.target` and
##   pulls in `xdg-desktop-autostart.target` (~/.config/autostart entries).
## The target is stopped again when nimdow exits.
## Set NIMDOW_NO_SESSION=1 to skip all of this (e.g. when nested for tests).

const
  sessionTarget = "nimdow-wl-session.target"
  exportedVars = [
    "WAYLAND_DISPLAY", "DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP",
    "XDG_SESSION_TYPE", "GTK_THEME", "QT_QPA_PLATFORMTHEME", "XCURSOR_THEME",
    "XCURSOR_SIZE"
  ]

var started = false

proc enabled(): bool =
  getEnv("NIMDOW_NO_SESSION").len == 0

proc run(cmd: string, args: openArray[string]): bool =
  let exe = findExe(cmd)
  if exe.len == 0:
    log cmd & " not found; skipping session setup step", lvlWarn
    return false
  try:
    let p = startProcess(exe, args = args, options = {poParentStreams})
    defer: p.close()
    result = p.waitForExit() == 0
  except CatchableError:
    log "running " & cmd & " failed: " & getCurrentExceptionMsg(), lvlWarn

proc startSession*() =
  ## Call after the Wayland connection is up and before autostart commands.
  if not enabled():
    return
  if not existsEnv("XDG_SESSION_TYPE"):
    putEnv("XDG_SESSION_TYPE", "wayland")
  if not existsEnv("XDG_CURRENT_DESKTOP"):
    putEnv("XDG_CURRENT_DESKTOP", "nimdow-wl")
  if not existsEnv("XDG_SESSION_DESKTOP"):
    putEnv("XDG_SESSION_DESKTOP", "nimdow-wl")

  var vars: seq[string]
  for v in exportedVars:
    if existsEnv(v):
      vars.add v
  if not run("dbus-update-activation-environment", @["--systemd"] & vars):
    log "could not export the session environment to D-Bus/systemd", lvlWarn

  # Portals started before the environment was exported (e.g. activated by
  # an early D-Bus call) cannot open the display: restart them if they run.
  discard run("systemctl", ["--user", "try-restart",
    "xdg-desktop-portal-gtk.service", "xdg-desktop-portal.service"])

  started = run("systemctl", ["--user", "start", sessionTarget])
  if not started:
    log "could not start " & sessionTarget & " (XDG autostart disabled)", lvlWarn

proc stopSession*() =
  if started:
    started = false
    discard run("systemctl", ["--user", "stop", sessionTarget])
