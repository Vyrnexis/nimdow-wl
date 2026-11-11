import
  std/[tables, sets, math],
  parsetoml,
  types,
  outputs,
  windows,
  seats,
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

proc tagSignature(this: WindowManager): seq[int] =
  ## The selected tags of all monitors, as one bit mask per monitor (after its ID).
  for monitor in this.sortedMonitors():
    var mask = 0
    for id in monitor.selectedTags:
      mask = mask or (1 shl id)
    result.add monitor.id
    result.add mask

proc manageMenu(this: WindowManager) =
  ## Closes the tray menu when the tags changed and lets the popups follow the
  ## tray's menu session. Manage sequence only.
  if this.menu == nil:
    return
  this.menu.beginManage()
  var
    bar: StatusBar
    area: tuple[x, y, w, h: int]
  let session = if this.tray != nil: this.tray.menu else: nil
  if session != nil:
    let sig = this.tagSignature()
    if this.menuTagGen != session.gen:
      this.menuTagGen = session.gen
      this.menuTagSig = sig
    elif sig != this.menuTagSig:
      this.tray.closeMenu()
    if this.tray.menu != nil:
      let (_, monitor) = this.monitors.find(session.anchorX, session.anchorY)
      if monitor != nil and monitor.statusBar != nil and monitor.isStatusBarEnabled:
        bar = monitor.statusBar
        let usable = monitor.usableArea()
        area = (usable.x.int, usable.y.int, usable.width.int, usable.height.int)
  this.menu.manage(this.tray, bar, area)

  # The tooltip of the tray icon under the pointer.
  var
    hoverBar: StatusBar
    hoverArea: tuple[x, y, w, h: int]
  let hovered = this.menu.hoverBar()
  if hovered != nil:
    for monitor in this.monitors.values():
      if monitor.statusBar == hovered and monitor.isStatusBarEnabled:
        hoverBar = hovered
        let usable = monitor.usableArea()
        hoverArea = (usable.x.int, usable.y.int, usable.width.int, usable.height.int)
        break
  this.menu.manageTooltip(this.tray, hoverBar, hoverArea)

proc timerTimeoutMs*(this: WindowManager): int =
  ## Event loop timeout for the menu/tooltip timers (-1: none).
  if this.menu == nil: -1 else: this.menu.timeoutMs()

proc fireTimers*(this: WindowManager) =
  ## Starts a manage sequence when a menu/tooltip timer is due.
  if this.menu != nil and this.menu.checkTimers():
    this.markDirty()

# ---------------------------------------------------------------------------
# Manage / render sequences
# ---------------------------------------------------------------------------

proc flushVisibility(client: Client) =
  if client.isVisible != client.sentVisible:
    if client.isVisible:
      river_window_v1_show(client.window)
    else:
      river_window_v1_hide(client.window)
    client.sentVisible = client.isVisible

proc applyManageState(this: WindowManager) =
  ## Sends window management state (and show/hide) to River.
  for monitor in this.monitors.values():
    # The mutators relayout themselves; this catches what they could not know.
    if monitor.layoutDirty:
      monitor.doLayout()
    for client in monitor.clients.items:
      if client.closeRequested:
        client.closeRequested = false
        river_window_v1_close(client.window)

      client.flushVisibility()

      # Fullscreen is handled by River (position and dimensions).
      if client.isFullscreen:
        if not client.sentFullscreen or client.sentFullscreenOutput != monitor.output:
          river_window_v1_fullscreen(client.window, monitor.output)
          if not client.sentFullscreen:
            river_window_v1_inform_fullscreen(client.window)
          client.sentFullscreen = true
          client.sentFullscreenOutput = monitor.output
      elif client.sentFullscreen:
        river_window_v1_exit_fullscreen(client.window)
        river_window_v1_inform_not_fullscreen(client.window)
        client.sentFullscreen = false
        client.sentFullscreenOutput = nil

      # Floating clients without a size yet (0) let the window choose.
      # New windows always get a proposal, even when hidden (e.g. ruled onto
      # another tag): it is their initial configure, without which they never
      # map. After that, only propose when the size changes.
      if client.isFullscreen:
        client.sentWidth = -1
        client.sentHeight = -1
      elif client.isNew or (client.isVisible and
          (client.width.int != client.sentWidth or client.height.int != client.sentHeight)):
        river_window_v1_propose_dimensions(
          client.window, client.width.int32, client.height.int32
        )
        client.sentWidth = client.width.int
        client.sentHeight = client.height.int

      if client.isNew:
        # nimdow draws its own borders; ask clients not to draw title bars.
        river_window_v1_use_ssd(client.window)
      # Tiled windows drop shadows/rounded corners.
      let tiled = not client.isFloating and not client.isFullscreen
      if tiled != client.sentTiled:
        river_window_v1_set_tiled(client.window,
          if tiled:
            RIVER_WINDOW_V1_EDGES_TOP or RIVER_WINDOW_V1_EDGES_BOTTOM or
              RIVER_WINDOW_V1_EDGES_LEFT or RIVER_WINDOW_V1_EDGES_RIGHT
          else:
            RIVER_WINDOW_V1_EDGES_NONE)
        client.sentTiled = tiled
      client.isNew = false

  for client in this.scratchpad:
    client.isVisible = false
    client.flushVisibility()
    client.isNew = false

  # Keyboard focus follows the selected client of the selected monitor.
  var focusTarget: Client
  if this.selectedMonitor != nil:
    focusTarget = this.selectedMonitor.taggedClients.currClient
  for seat in this.seats:
    if seat.layerFocus == lfExclusive:
      # A layer surface holds the keyboard; River ignores focus requests until
      # focus_none, after which the window is focused again.
      continue
    let menuShell = if this.menu != nil: this.menu.keyboardShell() else: nil
    if menuShell != nil:
      # The tray menu takes the keyboard while it is open.
      if seat.focusedShell != menuShell:
        river_seat_v1_focus_shell_surface(seat.obj, menuShell)
        seat.focusedShell = menuShell
        seat.focused = nil
      continue
    if seat.focusedShell != nil:
      # Back to the window that had the focus.
      seat.focusedShell = nil
      seat.focused = nil
      if focusTarget == nil:
        river_seat_v1_clear_focus(seat.obj)
    if focusTarget != nil:
      if seat.focused != focusTarget.window:
        river_seat_v1_focus_window(seat.obj, focusTarget.window)
        seat.focused = focusTarget.window
    elif seat.focused != nil:
      river_seat_v1_clear_focus(seat.obj)
      seat.focused = nil

  # New layer surfaces without an output go to the selected monitor.
  if this.selectedMonitor != nil and
      (this.layerDefault == nil or this.layerDefault.monitor != this.selectedMonitor):
    for output in this.outputs:
      if output.monitor == this.selectedMonitor and output.layerOutput != nil:
        river_layer_shell_output_v1_set_default(output.layerOutput)
        this.layerDefault = output
        break

  # Move the pointer along with a monitor focus change.
  if this.warpMonitor != nil and this.seats.len > 0:
    var x, y: int
    let client = this.warpClient
    if client != nil and not client.isFullscreen and client.isVisible:
      x = client.x + client.totalWidth div 2
      y = client.y + client.totalHeight div 2
    else:
      let center = this.warpMonitor.area.center()
      x = center.x.int
      y = center.y.int
    river_seat_v1_pointer_warp(this.seats[0].obj, x.int32, y.int32)
  this.warpMonitor = nil
  this.warpClient = nil

proc onManageStart*(this: WindowManager) =
  this.syncOutputs()

  # Remove closed windows.
  let closed = this.closedClients
  this.closedClients.setLen 0
  for client in closed:
    this.destroyClient(client)

  # The selected monitor follows the pointer.
  for seat in this.seats:
    if seat.pointerChanged:
      seat.pointerChanged = false
      let (_, monitor) = this.monitors.find(seat.pointerX.int, seat.pointerY.int)
      if monitor != nil:
        this.selectedMonitor = monitor

  this.assignUnassigned()
  this.syncSeats()

  # Client requests and changed hints.
  var requests: seq[tuple[monitor: Monitor, client: Client]]
  for monitor in this.monitors.values():
    for client in monitor.clients.items:
      if client.titleChanged or client.hintsDirty or
         client.fullscreenRequest != frNone or client.pointerRequest != prNone:
        requests.add (monitor, client)
  for (monitor, client) in requests:
    if client.titleChanged:
      this.applyLateRules(client, monitor)
    if client.hintsDirty:
      this.applyHints(client, monitor)
    case client.fullscreenRequest
    of frEnter: monitor.setFullscreen(client, true)
    of frExit: monitor.setFullscreen(client, false)
    of frNone: discard
    client.fullscreenRequest = frNone
    if client.pointerRequest != prNone:
      for seat in this.seats:
        if seat.obj == client.pointerRequestSeat:
          this.startSeatOp(
            seat, client, client.pointerRequest,
            if client.pointerRequest == prMove: 0'u32
            else: client.pointerRequestEdges
          )
      client.pointerRequest = prNone

  # Click-to-focus.
  for seat in this.seats:
    if seat.interacted != nil:
      let client = this.findClient(seat.interacted)
      seat.interacted = nil
      if seat.layerFocus == lfNonExclusive:
        # A click on a window takes focus back from the layer surface.
        seat.focused = nil
      # A click on a window dismisses the tray menu.
      if this.tray != nil:
        this.tray.closeMenu()
      if client != nil:
        this.selectClient(client)

  this.handleBarClicks()

  # modKey + button: move/resize the window under the pointer.
  for seat in this.seats:
    let pending = seat.pendingPointerOp
    seat.pendingPointerOp = prNone
    if pending != prNone and seat.hovered != nil:
      this.startSeatOp(
        seat, this.findClient(seat.hovered), pending,
        if pending == prMove: 0'u32
        else: RIVER_WINDOW_V1_EDGES_BOTTOM or RIVER_WINDOW_V1_EDGES_RIGHT
      )

  # Key bindings. Actions may reload the config, so work on a copy.
  let combos = this.pressedCombos
  this.pressedCombos.setLen 0
  for combo in combos:
    if this.selectedMonitor != nil and this.config.keyComboTable.hasKey(combo) and
       this.isActive(combo):
      try:
        this.config.keyComboTable[combo](combo)
      except CatchableError:
        log "Key action failed: " & getCurrentExceptionMsg(), lvlError
  # A reload in the loop above needs its bindings now.
  this.syncSeats()

  for seat in this.seats:
    this.manageSeatOp(seat)

  this.manageMenu()
  this.applyManageState()
  river_window_manager_v1_manage_finish(this.manager)

proc colorChannel(value: int, shift: int): uint32 =
  ## 8-bit channel to the 32-bit range used by River.
  uint32((value shr shift) and 0xff) * 0x01010101'u32

proc centerOnMonitor(client: Client, monitor: Monitor) =
  ## Centers a floating client whose size is known (the size it was given, or
  ## what the window chose) in the monitor's usable area.
  if client.width == 0: client.width = max(client.reportedWidth, 0).uint
  if client.height == 0: client.height = max(client.reportedHeight, 0).uint
  if client.width == 0 or client.height == 0:
    return
  let area = monitor.usableArea()
  # Larger than the usable area: use the floating percentages instead.
  let settings = monitor.windowSettings
  if client.totalWidth > area.width.int:
    client.width = percentArea(
      area, settings.floatingWidth, settings.floatingHeight, client.borderWidth).width
  if client.totalHeight > area.height.int:
    client.height = percentArea(
      area, settings.floatingWidth, settings.floatingHeight, client.borderWidth).height
  client.x = (area.x.float + (area.width.float - client.totalWidth.float) / 2).int
  client.y = (area.y.float + (area.height.float - client.totalHeight.float) / 2).int
  client.needsCenter = false

proc applyRenderState(this: WindowManager) =
  ## Sends rendering state (position, borders, stacking) to River.
  var focusedClient: Client
  if this.selectedMonitor != nil:
    focusedClient = this.selectedMonitor.taggedClients.currClient
  # No window is focused while a layer surface (launcher, ...) holds the keyboard.
  for seat in this.seats:
    if seat.layerFocus == lfExclusive:
      focusedClient = nil

  let trayOn = this.trayMonitor()
  for monitor in this.monitors.values():
    let settings = monitor.windowSettings
    if monitor.statusBar != nil:
      monitor.statusBar.setTray(if monitor == trayOn: this.tray else: nil)
      monitor.syncStatusBar(monitor == this.selectedMonitor)
      # Below the layer surfaces reserving space at the top.
      monitor.statusBar.flush(
        monitor.area.x + monitor.reserved.left.int,
        monitor.area.y + monitor.reserved.top.int,
        monitor.area.width.int - monitor.reserved.left.int - monitor.reserved.right.int,
        monitor.isStatusBarEnabled
      )
    for client in monitor.clients.items:
      if not client.isVisible:
        continue
      if client.needsCenter and client.isFloating:
        client.centerOnMonitor(monitor)
      let color =
        if client.isUrgent: settings.borderColorUrgent
        elif client == focusedClient: settings.borderColorFocused
        else: settings.borderColorUnfocused
      let bw = if client.isFullscreen: 0'i32 else: client.borderWidth.int32
      # River positions fullscreen windows itself. Layout areas include the
      # border; River positions the window content.
      if client.isFullscreen:
        client.sentPosition = false
      elif not client.sentPosition or client.sentX != client.x + bw.int or
           client.sentY != client.y + bw.int:
        river_node_v1_set_position(
          client.node, (client.x + bw).int32, (client.y + bw).int32
        )
        client.sentX = client.x + bw.int
        client.sentY = client.y + bw.int
        client.sentPosition = true
      if not client.sentBorders or client.sentBorderWidth != bw or
         client.sentBorderColor != color:
        river_window_v1_set_borders(
          client.window,
          RIVER_WINDOW_V1_EDGES_TOP or RIVER_WINDOW_V1_EDGES_BOTTOM or
            RIVER_WINDOW_V1_EDGES_LEFT or RIVER_WINDOW_V1_EDGES_RIGHT,
          bw,
          colorChannel(color, 16), colorChannel(color, 8), colorChannel(color, 0),
          0xffffffff'u32
        )
        client.sentBorderWidth = bw
        client.sentBorderColor = color
        client.sentBorders = true

    # Stacking, bottom to top: tiled, floating (least recently selected
    # first), status bar, fullscreen. River does not render shell surfaces
    # below the top fullscreen window, so the bar hides while one is shown.
    # Only sent when the order changed.
    var stack: seq[RiverNodeV1]
    for client in monitor.clientSelection:
      if client.isVisible and not client.isFloating and not client.isFullscreen:
        stack.add client.node
    for client in monitor.clientSelection:
      if client.isVisible and client.isFloating and not client.isFullscreen:
        stack.add client.node
    if monitor.statusBar != nil:
      stack.add monitor.statusBar.node
    for client in monitor.clientSelection:
      if client.isVisible and client.isFullscreen:
        stack.add client.node
    if stack != monitor.sentStack:
      for node in stack:
        river_node_v1_place_top(node)
      monitor.sentStack = stack

  # The tray menu above everything.
  if this.menu != nil:
    this.menu.flush()

proc onRenderStart*(this: WindowManager) =
  this.applyRenderState()
  river_window_manager_v1_render_finish(this.manager)
