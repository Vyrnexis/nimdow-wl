import
  std/[json, tables, math, strutils, sequtils, algorithm],
  parsetoml,
  clientlist,
  monitor,
  area,
  ../bar/statusbar,
  ../tray/traymenu,
  ../tray/tray,
  ../config/configloader,
  ../wl/client as wlclient,
  ../wl/protocols/[river_window_management_v1, river_xkb_bindings_v1, river_layer_shell_v1]

type
  Output* = ref object
    obj*: RiverOutputV1
    x*, y*, width*, height*: int32
    hasGeometry*: bool
    removed*: bool
    monitor*: Monitor
    ## Nil when the layer shell is unavailable.
    layerOutput*: RiverLayerShellOutputV1
    ## The area left by layer surfaces' exclusive zones (global coordinates).
    freeX*, freeY*, freeWidth*, freeHeight*: int32
    hasFreeArea*: bool

  XkbBinding* = ref object
    obj*: RiverXkbBindingV1
    combo*: KeyCombo

  PointerBinding* = ref object
    obj*: RiverPointerBindingV1
    seat*: Seat
    kind*: PointerRequestKind

  SeatOp* = enum
    soNone, soMove, soResize

  ## Keyboard focus held by a layer shell surface (launcher, lock screen, ...).
  LayerFocus* = enum
    lfNone, lfNonExclusive, lfExclusive

  Seat* = ref object
    obj*: RiverSeatV1
    isNew*, removed*: bool
    layerSeat*: RiverLayerShellSeatV1
    layerFocus*: LayerFocus
    xkbBindings*: seq[XkbBinding]
    pointerBindings*: seq[PointerBinding]
    ## Window under the pointer.
    hovered*: Window
    pointerX*, pointerY*: int32
    pointerChanged*: bool
    ## Set by a pointer binding (modKey + button) and handled in the manage sequence.
    pendingPointerOp*: PointerRequestKind
    # Interactive move/resize (river_seat_v1.op_start_pointer).
    op*: SeatOp
    opClient*: Client
    ## The client's area when its first op_delta arrived.
    opStart*: Area
    ## The client has been made floating and the start area was recorded.
    opStarted*: bool
    opDx*, opDy*: int32
    opRelease*: bool
    opEdges*: uint32
    ## Window that was last sent to River as keyboard focus.
    focused*: Window
    ## Shell surface (a tray menu popup) that was last sent as keyboard focus.
    focusedShell*: RiverShellSurfaceV1
    ## Window interacted with (clicked) since the last manage sequence.
    interacted*: Window

  WindowManager* = ref object
    display*: WlDisplay
    manager*: RiverWindowManagerV1
    xkbBindings*: RiverXkbBindingsV1
    ## Nil when River does not offer layer shell: layer surfaces are then
    ## closed by River.
    layerShell*: RiverLayerShellV1
    ## The output set as default for new layer surfaces.
    layerDefault*: Output
    config*: Config
    outputs*: seq[Output]
    monitors*: OrderedTable[MonitorID, Monitor]
    selectedMonitor*: Monitor
    seats*: seq[Seat]
    ## Clients that are not on any monitor (new, or their monitor went away).
    unassigned*: seq[Client]
    ## Hidden clients, not on any monitor. Last in, first out.
    scratchpad*: seq[Client]
    ## Windows River reported closed, destroyed at the next manage sequence.
    closedClients*: seq[Client]
    ## `sortedMonitors`, until the monitors or their areas change.
    sortedCache*: seq[Monitor]
    sortedDirty*: bool
    ## The pointer is moved here (to the client, else the monitor's center) in
    ## the next manage sequence.
    warpMonitor*: Monitor
    warpClient*: Client
    ## Nil when the status bar is unavailable.
    barCtx*: BarContext
    ## The system tray; nil when disabled or without a D-Bus session bus.
    tray*: Tray
    ## The popups of the tray's context menu; nil without the bar.
    menu*: MenuManager
    ## The tags (all monitors) when the open menu was first seen: it closes
    ## when they change.
    menuTagGen*: int
    menuTagSig*: seq[int]
    ## The status as set with `setStatus` (may contain per monitor statuses).
    status*: string
    ## Key combos pressed since the last manage sequence.
    pressedCombos*: seq[KeyCombo]
    bindingsDirty*: bool
    ## The session is locked (ext-session-lock): the bindings are disabled,
    ## except the `whileLocked` ones. `lockApplied` is what the bindings show.
    locked*, lockApplied*: bool

var wm*: WindowManager

proc markDirty*(this: WindowManager) =
  ## Ask River to start a manage sequence (used after actions that ran
  ## outside of one).
  river_window_manager_v1_manage_dirty(this.manager)

template dropAt*[T](s: var seq[T], item: T) =
  let i = s.find(item)
  if i >= 0: s.delete i

iterator allClients*(this: WindowManager): Client =
  for monitor in this.monitors.values():
    for client in monitor.clients.items:
      yield client

proc findClient*(this: WindowManager, window: Window): Client =
  for client in this.allClients:
    if client.window == window:
      return client
  for client in this.unassigned:
    if client.window == window:
      return client
  for client in this.scratchpad:
    if client.window == window:
      return client

proc sortedMonitors*(this: WindowManager): seq[Monitor] =
  ## Monitors ordered by position (x, then y).
  if this.sortedDirty:
    this.sortedCache.setLen 0
    for monitor in this.monitors.values():
      this.sortedCache.add monitor
    this.sortedCache.sort(proc(a, b: Monitor): int =
      result = cmp(a.area.x, b.area.x)
      if result == 0:
        result = cmp(a.area.y, b.area.y)
    )
    this.sortedDirty = false
  return this.sortedCache

proc monitorOf*(this: WindowManager, client: Client): Monitor =
  ## The monitor holding the client (nil: none).
  if client.monitorID > 0:
    return this.monitors.getOrDefault(client.monitorID)
