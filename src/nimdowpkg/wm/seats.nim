import
  std/[tables, math],
  parsetoml,
  types,
  actions,
  windows,
  clientlist,
  monitor,
  area,
  ../bar/statusbar,
  ../tray/traymenu,
  ../tray/tray,
  ../config/configloader,
  ../config/keys,
  ../wl/protocols/[river_window_management_v1, river_xkb_bindings_v1, river_layer_shell_v1]

# ---------------------------------------------------------------------------
# Seats and key bindings
# ---------------------------------------------------------------------------

proc xkbBindingPressed(data: pointer, obj: RiverXkbBindingV1) {.cdecl.} =
  wm.pressedCombos.add cast[XkbBinding](data).combo

var xkbBindingListener = river_xkb_binding_v1_noop_listener()
xkbBindingListener.pressed = xkbBindingPressed

proc pointerBindingPressed(data: pointer, obj: RiverPointerBindingV1) {.cdecl.} =
  let binding = cast[PointerBinding](data)
  binding.seat.pendingPointerOp = binding.kind

var pointerBindingListener = river_pointer_binding_v1_noop_listener()
pointerBindingListener.pressed = pointerBindingPressed

const
  BtnLeft = 0x110'u32
  BtnRight = 0x111'u32

const EscapeCombo* = ("Escape", 0'u32)

proc destroyBindings(seat: Seat) =
  if seat.escapeBinding != nil:
    river_xkb_binding_v1_destroy(seat.escapeBinding.obj)
    GC_unref seat.escapeBinding
    seat.escapeBinding = nil
    seat.escapeOn = false
  for binding in seat.xkbBindings:
    river_xkb_binding_v1_destroy(binding.obj)
    GC_unref binding
  seat.xkbBindings.setLen 0
  for binding in seat.pointerBindings:
    river_pointer_binding_v1_destroy(binding.obj)
    GC_unref binding
  seat.pointerBindings.setLen 0

proc isActive*(this: WindowManager, combo: KeyCombo): bool =
  not this.locked or combo in this.config.whileLockedCombos

proc applyLock(this: WindowManager, seat: Seat) =
  ## Enables or disables the existing bindings for the lock state.
  for binding in seat.xkbBindings:
    if this.isActive(binding.combo):
      river_xkb_binding_v1_enable(binding.obj)
    else:
      river_xkb_binding_v1_disable(binding.obj)
  for binding in seat.pointerBindings:
    if this.locked:
      river_pointer_binding_v1_disable(binding.obj)
    else:
      river_pointer_binding_v1_enable(binding.obj)

proc newXkbBinding(this: WindowManager, seat: Seat, combo: KeyCombo): XkbBinding =
  result = XkbBinding(combo: combo)
  result.obj = river_xkb_bindings_v1_get_xkb_binding(
    this.xkbBindings, seat.obj, combo.key.toKeysym(), combo.modifiers
  )
  GC_ref result
  discard river_xkb_binding_v1_add_listener(
    result.obj, addr xkbBindingListener, cast[pointer](result)
  )

proc syncEscape(this: WindowManager, seat: Seat) =
  ## Escape is only taken from the applications while the hotkey overlay is open.
  if seat.escapeBinding != nil and seat.escapeOn != this.overlayOpen:
    seat.escapeOn = this.overlayOpen
    if seat.escapeOn:
      river_xkb_binding_v1_enable(seat.escapeBinding.obj)
    else:
      river_xkb_binding_v1_disable(seat.escapeBinding.obj)

proc createBindings(this: WindowManager, seat: Seat) =
  for combo in this.config.keyComboTable.keys():
    let binding = this.newXkbBinding(seat, combo)
    if this.isActive(combo):
      river_xkb_binding_v1_enable(binding.obj)
    seat.xkbBindings.add binding
  if EscapeCombo notin this.config.keyComboTable:
    seat.escapeBinding = this.newXkbBinding(seat, EscapeCombo)

  # modKey + left button moves, modKey + right button resizes.
  let modKey = this.config.windowSettings.modKey.uint32
  for (button, kind) in [(BtnLeft, prMove), (BtnRight, prResize)]:
    let binding = PointerBinding(seat: seat, kind: kind)
    binding.obj = river_seat_v1_get_pointer_binding(seat.obj, button, modKey)
    GC_ref binding
    discard river_pointer_binding_v1_add_listener(
      binding.obj, addr pointerBindingListener, cast[pointer](binding)
    )
    if not this.locked:
      river_pointer_binding_v1_enable(binding.obj)
    seat.pointerBindings.add binding

proc layerFocusExclusive(data: pointer, obj: RiverLayerShellSeatV1) {.cdecl.} =
  cast[Seat](data).layerFocus = lfExclusive

proc layerFocusNonExclusive(data: pointer, obj: RiverLayerShellSeatV1) {.cdecl.} =
  cast[Seat](data).layerFocus = lfNonExclusive

proc layerFocusNone(data: pointer, obj: RiverLayerShellSeatV1) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.layerFocus = lfNone
  # Return focus to the window: it is sent again in the next manage sequence.
  seat.focused = nil

var layerSeatListener = river_layer_shell_seat_v1_noop_listener()
layerSeatListener.focus_exclusive = layerFocusExclusive
layerSeatListener.focus_non_exclusive = layerFocusNonExclusive
layerSeatListener.focus_none = layerFocusNone

proc seatRemoved(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).removed = true

proc seatWindowInteraction(data: pointer, obj: RiverSeatV1, window: RiverWindowV1) {.cdecl.} =
  cast[Seat](data).interacted = window

proc seatPointerEnter(data: pointer, obj: RiverSeatV1, window: RiverWindowV1) {.cdecl.} =
  cast[Seat](data).hovered = window

proc seatPointerLeave(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).hovered = nil

proc seatPointerPosition(data: pointer, obj: RiverSeatV1, x, y: int32) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.pointerX = x
  seat.pointerY = y
  seat.pointerChanged = true

proc seatOpDelta(data: pointer, obj: RiverSeatV1, dx, dy: int32) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.opDx = dx
  seat.opDy = dy

proc seatOpRelease(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).opRelease = true

var seatListener = river_seat_v1_noop_listener()
seatListener.removed = seatRemoved
seatListener.window_interaction = seatWindowInteraction
seatListener.pointer_enter = seatPointerEnter
seatListener.pointer_leave = seatPointerLeave
seatListener.pointer_position = seatPointerPosition
seatListener.op_delta = seatOpDelta
seatListener.op_release = seatOpRelease

proc wmSeat*(data: pointer, obj: RiverWindowManagerV1, s: RiverSeatV1) {.cdecl.} =
  let seat = Seat(obj: s, isNew: true)
  GC_ref seat
  discard river_seat_v1_add_listener(s, addr seatListener, cast[pointer](seat))
  if wm.layerShell != nil:
    seat.layerSeat = river_layer_shell_v1_get_seat(wm.layerShell, s)
    discard river_layer_shell_seat_v1_add_listener(
      seat.layerSeat, addr layerSeatListener, cast[pointer](seat)
    )
  wm.seats.add seat

proc syncSeats*(this: WindowManager) =
  var gone: seq[Seat]
  for seat in this.seats:
    if seat.removed:
      gone.add seat
    elif seat.isNew or this.bindingsDirty:
      seat.destroyBindings()
      this.createBindings(seat)
      seat.isNew = false
    elif this.locked != this.lockApplied:
      this.applyLock(seat)
    if not seat.removed:
      this.syncEscape(seat)
  for seat in gone:
    seat.destroyBindings()
    if seat.layerSeat != nil:
      river_layer_shell_seat_v1_destroy(seat.layerSeat)
    river_seat_v1_destroy(seat.obj)
    this.seats.dropAt seat
    GC_unref seat
  this.bindingsDirty = false
  this.lockApplied = this.locked

# ---------------------------------------------------------------------------
# Status bar clicks
# ---------------------------------------------------------------------------

proc handleBarClicks*(this: WindowManager) =
  ## Handles the clicks and scrolls queued by the bars' wl_pointer listeners.
  ## Manage sequence only.
  if this.barCtx == nil:
    return
  let clicks = this.barCtx.clicks
  this.barCtx.clicks.setLen 0
  for click in clicks:
    var monitor: Monitor
    for m in this.monitors.values():
      if m.statusBar == click.bar:
        monitor = m
        break
    if monitor == nil:
      continue
    this.selectedMonitor = monitor

    let
      bar = click.bar
      trayIcon = bar.trayIconAt(click.x, click.y)
    if trayIcon.uid >= 0 and this.tray != nil:
      if this.menu != nil:
        this.menu.tooltipClicked(trayIcon.uid)
      this.tray.click(trayIcon.uid, click.button, trayIcon.x, trayIcon.y)
      continue
    # Any other click on the bar dismisses the tray menu.
    if this.tray != nil:
      this.tray.closeMenu()
    let clicked = bar.regionAt(click.x, click.y)
    if clicked.regionID == -1:
      # Nothing was clicked
      continue

    if clicked.regionID in 0 ..< bar.tagCount:
      case click.button
      of 4, 5:
        let
          scrollUp = click.button == 4
          left = scrollUp != this.config.reverseTagScrolling
          tag = if left: this.findRelativeTag(-1) else: this.findRelativeTag(1)
        if tag != nil:
          this.goToTag(tag.id)
      else:
        this.goToTag(clicked.regionID + 1)
      continue

    # The window title is region 0, the status regions follow.
    let regionID =
      if clicked.regionID == bar.tagCount: 0
      else: clicked.regionID - bar.tagCount
    if this.config.regionClickActionTable.hasKey(regionID):
      this.config.regionClickActionTable[regionID](
        clicked.index,
        clicked.width,
        clicked.regionCord,
        clicked.clickCord,
        click.button
      )

# ---------------------------------------------------------------------------
# Interactive move/resize
# ---------------------------------------------------------------------------

proc selectClient*(this: WindowManager, client: Client) =
  let monitor = this.monitorOf(client)
  if monitor != nil:
    this.selectedMonitor = monitor
    monitor.setSelectedClient(client)

proc startSeatOp*(
  this: WindowManager, seat: Seat, client: Client, kind: PointerRequestKind, edges: uint32
) =
  ## Starts moving/resizing the client with the seat's pointer. The client
  ## becomes floating with the first motion (op_delta).
  if seat.op != prNone or client == nil or client.isFullscreen or
     this.monitorOf(client) == nil:
    return
  this.selectClient(client)
  river_seat_v1_op_start_pointer(seat.obj)
  seat.op = kind
  seat.opClient = client
  seat.opEdges = edges
  seat.opStarted = false
  seat.opRelease = false
  seat.opDx = 0
  seat.opDy = 0
  if seat.op == prResize:
    river_window_v1_inform_resize_start(client.window)

proc manageSeatOp*(this: WindowManager, seat: Seat) =
  ## Advances the interactive op: the client's area follows the pointer.
  if seat.op == prNone:
    return
  let client = seat.opClient
  let monitor = this.monitorOf(client)
  if monitor == nil:
    seat.endSeatOp()
    return

  if not seat.opStarted and (seat.opDx != 0 or seat.opDy != 0):
    seat.opStarted = true
    monitor.setFloating(client, true)
    # A window that has not been sized by us yet is moved/resized as it is.
    if client.width == 0: client.width = max(client.reportedWidth, 1).uint
    if client.height == 0: client.height = max(client.reportedHeight, 1).uint
    client.needsCenter = false
    seat.opStart = client.area

  if seat.opStarted:
    let start = seat.opStart
    if seat.op == prMove:
      client.x = start.x + seat.opDx.int
      client.y = start.y + seat.opDy.int
    else:
      var
        width = start.width.int
        height = start.height.int
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_LEFT) != 0: width -= seat.opDx
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_RIGHT) != 0: width += seat.opDx
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_TOP) != 0: height -= seat.opDy
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_BOTTOM) != 0: height += seat.opDy
      width = max(width, 1)
      height = max(height, 1)
      var x = start.x
      var y = start.y
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_LEFT) != 0:
        x += start.width.int - width
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_TOP) != 0:
        y += start.height.int - height
      client.resize(x, y, width.uint, height.uint)

  if seat.opRelease:
    let started = seat.opStarted
    seat.endSeatOp()
    if started:
      # Dropped on another monitor: the client belongs to that monitor now.
      let
        centerX = client.x + client.totalWidth div 2
        centerY = client.y + client.totalHeight div 2
        target = this.monitors.find(centerX, centerY)
      if target != nil and target != monitor:
        this.moveClientToMonitor(client, target, keepPosition = true)
