import
  std/[times, tables, math],
  parsetoml,
  types,
  clientlist,
  monitor,
  area,
  ../config/configloader,
  ../config/apprules,
  ../wl/protocols/[river_window_management_v1, river_xkb_bindings_v1, river_layer_shell_v1],
  ../sys/logger

# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------

proc windowClosed(data: pointer, obj: RiverWindowV1) {.cdecl.} =
  let client = cast[Client](data)
  if not client.isClosed:
    client.isClosed = true
    wm.closedClients.add client

proc windowDimensions(data: pointer, obj: RiverWindowV1, width, height: int32) {.cdecl.} =
  let client = cast[Client](data)
  client.reportedWidth = width
  client.reportedHeight = height

proc windowAppId(data: pointer, obj: RiverWindowV1, appId: cstring) {.cdecl.} =
  cast[Client](data).appId = if appId.isNil: "" else: $appId

proc windowTitle(data: pointer, obj: RiverWindowV1, title: cstring) {.cdecl.} =
  let client = cast[Client](data)
  let newTitle = if title.isNil: "" else: $title
  if newTitle.len > 0 and newTitle != client.title:
    client.titleChanged = true
  client.title = newTitle

proc windowDimensionsHint(
  data: pointer, obj: RiverWindowV1, minWidth, minHeight, maxWidth, maxHeight: int32
) {.cdecl.} =
  let client = cast[Client](data)
  client.minWidth = minWidth
  client.minHeight = minHeight
  client.maxWidth = maxWidth
  client.maxHeight = maxHeight
  client.hintsDirty = true

proc windowParent(data: pointer, obj: RiverWindowV1, parent: RiverWindowV1) {.cdecl.} =
  let client = cast[Client](data)
  client.hasParent = not parent.isNil
  client.hintsDirty = true

proc windowFullscreenRequested(
  data: pointer, obj: RiverWindowV1, output: RiverOutputV1
) {.cdecl.} =
  cast[Client](data).fullscreenRequest = frEnter

proc windowExitFullscreenRequested(data: pointer, obj: RiverWindowV1) {.cdecl.} =
  cast[Client](data).fullscreenRequest = frExit

proc windowPointerMoveRequested(
  data: pointer, obj: RiverWindowV1, seat: RiverSeatV1
) {.cdecl.} =
  let client = cast[Client](data)
  client.pointerRequest = prMove
  client.pointerRequestSeat = seat

proc windowPointerResizeRequested(
  data: pointer, obj: RiverWindowV1, seat: RiverSeatV1, edges: uint32
) {.cdecl.} =
  let client = cast[Client](data)
  client.pointerRequest = prResize
  client.pointerRequestSeat = seat
  client.pointerRequestEdges = edges

# maximize_requested/unmaximize_requested are ignored, which the protocol
# allows ("free to honor or ignore"): tiled windows stay tiled and nimdow never
# tells a window that it is maximized, so no inform_(un)maximized reply is due.
var windowListener = river_window_v1_noop_listener()
windowListener.closed = windowClosed
windowListener.dimensions = windowDimensions
windowListener.app_id = windowAppId
windowListener.title = windowTitle
windowListener.dimensions_hint = windowDimensionsHint
windowListener.parent = windowParent
windowListener.fullscreen_requested = windowFullscreenRequested
windowListener.exit_fullscreen_requested = windowExitFullscreenRequested
windowListener.pointer_move_requested = windowPointerMoveRequested
windowListener.pointer_resize_requested = windowPointerResizeRequested

proc wmWindow*(data: pointer, obj: RiverWindowManagerV1, w: RiverWindowV1) {.cdecl.} =
  let client = newClient(w)
  client.node = river_window_v1_get_node(w)
  GC_ref client
  discard river_window_v1_add_listener(w, addr windowListener, cast[pointer](client))
  # Placed on a monitor at the next manage sequence.
  wm.unassigned.add client

proc endSeatOp*(seat: Seat) =
  ## Ends the interactive op of the seat. Manage sequence only.
  if seat.op == soResize and seat.opClient != nil:
    river_window_v1_inform_resize_end(seat.opClient.window)
  river_seat_v1_op_end(seat.obj)
  seat.op = soNone
  seat.opClient = nil
  seat.opStarted = false
  seat.opRelease = false

proc destroyClient*(this: WindowManager, client: Client) =
  let monitor = this.monitorOf(client)
  if monitor != nil and monitor.removeWindow(client.window):
    monitor.doLayout()
  this.unassigned.dropAt client
  this.scratchpad.dropAt client
  if this.warpClient == client: this.warpClient = nil
  for seat in this.seats:
    if seat.focused == client.window: seat.focused = nil
    if seat.interacted == client.window: seat.interacted = nil
    if seat.hovered == client.window: seat.hovered = nil
    if seat.opClient == client: seat.endSeatOp()
  river_window_v1_destroy(client.window)
  GC_unref client

proc findAppRule(this: WindowManager, client: Client): AppRule =
  ## The first rule matching the client. The app_id serves as both the
  ## class and the instance.
  for rule in this.config.appRules:
    if rule.matches(client.title, client.appId, client.appId):
      return rule

proc centerIfAtOrigin(client: Client, monitor: Monitor) =
  ## Original centerClientIfNeeded: a floating client at the top-left corner
  ## of the usable area is centered once its size is known.
  let usable = monitor.usableArea()
  if client.x <= usable.x and client.y <= usable.y:
    client.needsCenter = true

proc applyHints*(this: WindowManager, client: Client, monitor: Monitor) =
  ## Dialogs/transients (a parent) and fixed size windows (min == max) float.
  client.hintsDirty = false
  let fixedSize =
    client.minWidth > 0 and client.minWidth == client.maxWidth and
    client.minHeight > 0 and client.minHeight == client.maxHeight
  client.isFixedSize = fixedSize
  if (client.hasParent or fixedSize) and not client.isFloating:
    if client.isFullscreen:
      # Not arranged by the layout once fullscreen is left.
      if fixedSize:
        client.isFloating = true
      return
    if monitor != nil:
      monitor.setFloating(client, true)
    else:
      client.isFloating = true
    # Hints often arrive after the window was already laid out as a tile, so
    # drop the tile geometry: a fixed size window gets exactly its size, and
    # every auto-floated window is centered.
    if fixedSize:
      client.width = client.minWidth.uint
      client.height = client.minHeight.uint
    client.needsCenter = true

proc applyRuleGeometry(client: Client, monitor: Monitor, rule: AppRule) =
  ## Position and size of a floating app rule. A position given by the rule is
  ## kept inside the usable area; without one the client is centered later.
  if rule.width > 0: client.width = rule.width.uint
  if rule.height > 0: client.height = rule.height.uint
  let usable = monitor.usableArea()
  if rule.x >= 0:
    let maxX =
      if client.width > 0: usable.x + usable.width.int - client.totalWidth
      else: usable.x + usable.width.int - 1
    client.x = clamp(monitor.area.x + rule.x, usable.x, max(usable.x, maxX))
  if rule.y >= 0:
    let maxY =
      if client.height > 0: usable.y + usable.height.int - client.totalHeight
      else: usable.y + usable.height.int - 1
    client.y = clamp(monitor.area.y + rule.y, usable.y, max(usable.y, maxY))

const
  ## Title rules are re-evaluated when the title arrives within this time of
  ## the window having been placed (see `applyLateRules`).
  LateRuleWindow = initDuration(milliseconds = 500)

proc hasTitleRules(this: WindowManager): bool =
  for rule in this.config.appRules:
    if rule.title.len > 0:
      return true

proc applyLateRules*(this: WindowManager, client: Client, monitor: Monitor) =
  ## Windows often set their title only after they were mapped, so a title-based
  ## rule can miss the first evaluation. When the first title arrives shortly
  ## after placement and no rule has matched yet, the rules run again. Only the
  ## tags and the floating/fullscreen state apply late (the window stays on its
  ## monitor).
  client.titleChanged = false
  if client.ruleApplied or getMonoTime() - client.placedAt > LateRuleWindow:
    return
  let rule = this.findAppRule(client)
  if rule == nil:
    return
  client.ruleApplied = true
  log "Applied app rule to \"" & client.appId & "\" after its title arrived: " & client.title
  if rule.tagIDs.len > 0:
    client.tagIDs = {}
    for tagID in rule.tagIDs:
      client.tagIDs.incl tagID
  case rule.state
  of wsFloating:
    monitor.setFloating(client, true)
    applyRuleGeometry(client, monitor, rule)
    client.centerIfAtOrigin(monitor)
  of wsFullscreen:
    monitor.setFullscreen(client, true)
  of wsNormal:
    discard
  monitor.doLayout()

proc assignUnassigned*(this: WindowManager) =
  ## Puts clients on a monitor (kept waiting if there is none yet): new clients
  ## by their app rule or on the selected monitor (which follows the pointer),
  ## clients of removed outputs on the selected monitor.
  ##
  ## A new client is held back for one manage sequence while its app_id (or its
  ## title, if any rule matches on titles) is still unknown, so rules see them.
  if this.selectedMonitor == nil or this.unassigned.len == 0:
    return
  let titleRules = this.hasTitleRules()
  var waiting: seq[Client]
  for client in this.unassigned:
    var
      monitor = this.selectedMonitor
      rule: AppRule
    if client.isNew:
      if not client.deferredForInfo and not client.isClosed and
         (client.appId.len == 0 or (titleRules and client.title.len == 0)):
        client.deferredForInfo = true
        waiting.add client
        continue
      rule = this.findAppRule(client)
      client.titleChanged = false
      client.ruleApplied = rule != nil
      client.placedAt = getMonoTime()
      client.borderWidth = this.config.windowSettings.borderWidth
      if rule != nil and rule.monitorID in 1 .. this.sortedMonitors().len:
        monitor = this.sortedMonitors()[rule.monitorID - 1]
      client.area = (monitor.area.x, monitor.area.y, 0.uint, 0.uint)

      if rule != nil:
        if rule.tagIDs.len > 0:
          client.tagIDs = {}
          for tagID in rule.tagIDs:
            client.tagIDs.incl tagID
        case rule.state
        of wsFloating:
          client.isFloating = true
          applyRuleGeometry(client, monitor, rule)
        of wsFullscreen:
          client.isFullscreen = true
        of wsNormal:
          discard

      monitor.addClient(client, rule == nil or rule.tagIDs.len == 0)
      this.applyHints(client, monitor)
      if client.isFloating:
        client.centerIfAtOrigin(monitor)
      if client.isFullscreen:
        # Relaid out (the other windows hidden) by `applyManageState`.
        monitor.setSelectedClient(client)
    else:
      monitor.addClient(client)
  this.unassigned = waiting
  if waiting.len > 0:
    # Nothing else may be going on: have River start another manage sequence.
    this.markDirty()
