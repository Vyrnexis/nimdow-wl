import
  std/[json, sets, math, os, algorithm],
  types,
  clientlist,
  monitor,
  area,
  ../bar/statusbar,
  ../tray/traymenu,
  ../wl/protocols/[river_window_management_v1, river_xkb_bindings_v1, river_layer_shell_v1],
  ../sys/logger,
  listutils

proc clientJson(this: WindowManager, client: Client, focused: Client): JsonNode =
  var tags: seq[int]
  for id in client.tagIDs:
    tags.add id.int
  tags.sort()
  %*{
    "app_id": client.appId,
    "title": client.title,
    "tags": tags,
    "floating": client.isFloating,
    "fullscreen": client.isFullscreen,
    "visible": client.isVisible,
    "focused": client == focused,
    "borderWidth": client.borderWidth.int,
    "x": client.x,
    "y": client.y,
    "width": client.width.int,
    "height": client.height.int,
    "reportedWidth": client.reportedWidth,
    "reportedHeight": client.reportedHeight
  }

proc dumpState*(this: WindowManager, path: string) =
  ## Debug/test aid (`nimdow-wl --dumpState [file]`): writes the window manager
  ## state as JSON to `path` (default `$XDG_RUNTIME_DIR/nimdow-wl-state.json`).
  ## The file is written atomically.
  var focused: Client
  if this.selectedMonitor != nil:
    focused = this.selectedMonitor.taggedClients.currClient
  var monitors = newJArray()
  for monitor in this.sortedMonitors():
    var selectedTags: seq[int]
    for id in monitor.selectedTags:
      selectedTags.add id.int
    selectedTags.sort()
    var clients = newJArray()
    for client in monitor.clients.items:
      clients.add this.clientJson(client, focused)
    var trayJson = newJArray()
    if monitor.statusBar != nil and monitor.isStatusBarEnabled:
      for region in monitor.statusBar.trayLayout():
        trayJson.add %*{
          "uid": region.uid, "id": region.id, "status": $region.status,
          "hasIcon": region.hasIcon, "icon": region.icon, "x": region.x, "width": region.width
        }
    monitors.add %*{
      "id": monitor.id.int,
      "selected": monitor == this.selectedMonitor,
      "area": {
        "x": monitor.area.x, "y": monitor.area.y,
        "width": monitor.area.width.int, "height": monitor.area.height.int
      },
      "reserved": {
        "top": monitor.reserved.top.int, "left": monitor.reserved.left.int,
        "bottom": monitor.reserved.bottom.int, "right": monitor.reserved.right.int
      },
      "selectedTags": selectedTags,
      "barVisible": monitor.statusBar != nil and monitor.isStatusBarEnabled,
      "barHeight": monitor.barHeight.int,
      "tray": trayJson,
      "clients": clients
    }
  var scratch = newJArray()
  for client in this.scratchpad:
    scratch.add this.clientJson(client, focused)
  var unassigned = newJArray()
  for client in this.unassigned:
    unassigned.add this.clientJson(client, focused)
  let state = %*{
    "menu": (if this.menu != nil: this.menu.dumpJson(this.tray) else: %*{"open": false}),
    "monitors": monitors,
    "scratchpad": scratch,
    "unassigned": unassigned,
    "focused": (if focused != nil: this.clientJson(focused, focused) else: newJNull())
  }
  let target =
    if path.len > 0: path
    else: getEnv("XDG_RUNTIME_DIR", "/tmp") / "nimdow-wl-state.json"
  try:
    let tmp = target & ".tmp"
    writeFile(tmp, $state)
    moveFile(tmp, target)
  except CatchableError:
    log "Failed to write the state to " & target & ": " & getCurrentExceptionMsg(), lvlError
