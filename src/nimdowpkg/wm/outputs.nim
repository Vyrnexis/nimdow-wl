import
  std/[tables, math, strutils, algorithm, parseutils],
  parsetoml,
  types,
  clientlist,
  monitor,
  area,
  ../bar/statusbar,
  ../tray/traymenu,
  ../tray/tray,
  ../config/configloader,
  ../wl/protocols/[river_window_management_v1, river_xkb_bindings_v1, river_layer_shell_v1],
  ../sys/logger,
  listutils

const
  ## Per monitor statuses: "NIMDOW_MONITOR_INDEX=0 first NIMDOW_MONITOR_INDEX=1 second"
  StatusMonitorPrefix = "NIMDOW_MONITOR_INDEX="

proc applyStatus(this: WindowManager) =
  ## Hands the status to the bars of all monitors.
  let statuses = this.status.split(StatusMonitorPrefix)
  if statuses.len == 1:
    for monitor in this.monitors.values():
      if monitor.statusBar != nil:
        monitor.statusBar.setStatus(statuses[0])
    return
  try:
    for rawStatus in statuses[1 .. statuses.high]:
      let
        monitorIndexAsStr = rawStatus[0 .. skipUntil(rawStatus, Whitespace) - 1]
        monitorID = parseInt(monitorIndexAsStr) + 1
      if not this.monitors.hasKey(monitorID):
        raise newException(ValueError, "monitor index " & monitorIndexAsStr & " is out of range")
      let monitor = this.monitors[monitorID]
      if monitor.statusBar != nil:
        var status = rawStatus
        status.removePrefix(monitorIndexAsStr)
        monitor.statusBar.setStatus(status)
  except ValueError:
    let msg = getCurrentExceptionMsg()
    for monitor in this.monitors.values():
      if monitor.statusBar != nil:
        monitor.statusBar.setStatus(msg)
    log msg, lvlError

proc trayMonitor*(this: WindowManager): Monitor =
  ## The monitor whose bar shows the tray.
  if this.tray == nil or not this.config.trayEnabled:
    return nil
  if this.config.trayMonitor <= 0:
    return this.selectedMonitor
  let monitors = this.sortedMonitors()
  if monitors.len == 0:
    return nil
  return monitors[min(this.config.trayMonitor, monitors.len) - 1]

proc startTray*(this: WindowManager) =
  ## Starts the StatusNotifier tray (needs the bar and the D-Bus session bus).
  if not this.config.trayEnabled or this.barCtx == nil or this.tray != nil:
    return
  this.tray = newTray(this.config.trayIconTheme, proc() = this.markDirty())

proc setStatus*(this: WindowManager, status: string): bool =
  ## Sets the text shown on the right of the status bars (`nimdow-wl --status`).
  ## Returns if it changed; only then must the caller `markDirty` so the bars
  ## are redrawn.
  if status == this.status:
    return false
  this.status = status
  this.applyStatus()
  return true

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

proc outputRemoved(data: pointer, obj: RiverOutputV1) {.cdecl.} =
  cast[Output](data).removed = true

proc outputPosition(data: pointer, obj: RiverOutputV1, x, y: int32) {.cdecl.} =
  let output = cast[Output](data)
  output.x = x
  output.y = y

proc outputDimensions(data: pointer, obj: RiverOutputV1, width, height: int32) {.cdecl.} =
  let output = cast[Output](data)
  output.width = width
  output.height = height
  output.hasGeometry = true

proc layerNonExclusiveArea(
  data: pointer, obj: RiverLayerShellOutputV1, x, y, width, height: int32
) {.cdecl.} =
  let output = cast[Output](data)
  output.freeX = x
  output.freeY = y
  output.freeWidth = width
  output.freeHeight = height
  output.hasFreeArea = true

var layerOutputListener = river_layer_shell_output_v1_noop_listener()
layerOutputListener.non_exclusive_area = layerNonExclusiveArea

var outputListener = river_output_v1_noop_listener()
outputListener.removed = outputRemoved
outputListener.position = outputPosition
outputListener.dimensions = outputDimensions

proc wmOutput*(data: pointer, obj: RiverWindowManagerV1, o: RiverOutputV1) {.cdecl.} =
  let output = Output(obj: o)
  GC_ref output
  discard river_output_v1_add_listener(o, addr outputListener, cast[pointer](output))
  if wm.layerShell != nil:
    output.layerOutput = river_layer_shell_v1_get_output(wm.layerShell, o)
    discard river_layer_shell_output_v1_add_listener(
      output.layerOutput, addr layerOutputListener, cast[pointer](output)
    )
  wm.outputs.add output

proc outputArea(output: Output): Area =
  (output.x.int, output.y.int, output.width.uint, output.height.uint)

proc reservedEdges(output: Output): LayoutOffset =
  ## Space taken by layer surfaces at each edge of the output.
  if not output.hasFreeArea:
    return
  let
    top = clamp(output.freeY - output.y, 0, output.height)
    left = clamp(output.freeX - output.x, 0, output.width)
    bottom = clamp(
      (output.y + output.height) - (output.freeY + output.freeHeight), 0, output.height
    )
    right = clamp(
      (output.x + output.width) - (output.freeX + output.freeWidth), 0, output.width
    )
  # Never reserve the whole output.
  if top + bottom >= output.height or left + right >= output.width:
    return
  (top.uint, left.uint, bottom.uint, right.uint)

proc syncOutputs*(this: WindowManager) =
  ## Creates monitors for new outputs (in position order), updates changed
  ## geometry and removes monitors of removed outputs (their clients move to
  ## another monitor).
  var gone: seq[Output]
  for output in this.outputs:
    if output.removed:
      gone.add output
      if output.monitor != nil:
        let monitor = output.monitor
        for client in monitor.clients.items:
          # Fullscreen is re-requested on the new monitor's output.
          client.sentFullscreen = false
          client.sentFullscreenOutput = nil
          client.monitorID = 0
          this.unassigned.add client
        if monitor.statusBar != nil:
          if this.tray != nil:
            # Its popups use the bar's font.
            this.tray.closeMenu()
            this.menu.manage(this.tray, nil, (0, 0, 0, 0))
          monitor.statusBar.destroy()
          monitor.statusBar = nil
        this.monitors.del monitor.id
        this.sortedDirty = true
        if this.warpMonitor == monitor:
          this.warpMonitor = nil
          this.warpClient = nil
        if this.selectedMonitor == monitor:
          this.selectedMonitor = nil
          for m in this.sortedMonitors():
            this.selectedMonitor = m
            break
    elif output.monitor != nil:
      let
        monitor = output.monitor
        reserved = output.reservedEdges()
      if output.hasGeometry and monitor.area != output.outputArea:
        monitor.area = output.outputArea
        monitor.reserved = reserved
        this.sortedDirty = true
        monitor.updateMonitor()
      elif monitor.reserved != reserved:
        # A layer surface (another bar, ...) was mapped, changed or went away.
        monitor.reserved = reserved
        monitor.updateMonitor()

  for output in gone:
    if output.layerOutput != nil:
      river_layer_shell_output_v1_destroy(output.layerOutput)
      output.layerOutput = nil
    if this.layerDefault == output:
      this.layerDefault = nil
    river_output_v1_destroy(output.obj)
    this.outputs.dropAt output
    GC_unref output

  var fresh: seq[Output]
  for output in this.outputs:
    if output.hasGeometry and output.monitor == nil:
      fresh.add output
  fresh.sort(proc(a, b: Output): int =
    result = cmp(a.x, b.x)
    if result == 0:
      result = cmp(a.y, b.y)
  )
  for output in fresh:
    # The lowest free ID: per monitor config and status indices (NIMDOW_MONITOR_INDEX)
    # then stay in step with the monitors' order after outputs come and go.
    var id = 1
    while this.monitors.hasKey(id):
      inc id
    output.monitor = newMonitor(id, output.obj, output.outputArea, this.config)
    output.monitor.reserved = output.reservedEdges()
    this.monitors[id] = output.monitor
    this.sortedDirty = true
    if this.barCtx != nil:
      let settings = output.monitor.monitorSettings
      output.monitor.statusBar = newStatusBar(
        this.barCtx, settings.barSettings, settings.tagSettings
      )
    # Applies the layer shell reservation and reserves the bar's space.
    output.monitor.updateMonitor()
    if this.selectedMonitor == nil:
      this.selectedMonitor = output.monitor
  if fresh.len > 0:
    this.applyStatus()
