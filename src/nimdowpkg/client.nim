import
  sets,
  std/monotimes

import
  area,
  taginfo,
  wl/protocols/river_window_management_v1

export monotimes

type
  PointerRequestKind* = enum
    prNone, prMove, prResize

  FullscreenRequest* = enum
    frNone, frEnter, frExit

  Window* = RiverWindowV1
  ## The river window handle is what identifies a client.

  Client* = ref object of RootObj
    window*: Window
    node*: RiverNodeV1
    ## The monitor whose client list holds this client (0: none).
    monitorID*: int
    tagIDs*: HashSet[TagID]
    # Desired state. Event handlers and actions only change these fields;
    # they are flushed to River during the next manage/render sequence.
    area*: Area
    borderWidth*: uint
    ## Desired visibility (the monitor's selected tags contain one of our tags).
    isVisible*: bool
    isFullscreen*: bool
    isFloating*: bool
    # Non-resizable
    isFixedSize*: bool
    isUrgent*: bool
    # Bookkeeping for the pending-state flush.
    ## No state has been sent to River for this client yet.
    isNew*: bool
    ## River told us the window is gone; destroyed at the next manage sequence.
    isClosed*: bool
    ## close() must be sent during the next manage sequence.
    closeRequested*: bool
    ## Last visibility sent to River.
    sentVisible*: bool
    ## Last dimensions proposed to River (-1 = nothing proposed yet). Every
    ## propose_dimensions makes River configure the window and wait for it,
    ## so only re-propose when the size actually changes.
    sentWidth*, sentHeight*: int
    ## Last position/borders sent to River (see `applyRenderState`); false
    ## until sent, and after River may have moved the window itself.
    sentPosition*, sentBorders*: bool
    sentX*, sentY*: int
    sentBorderWidth*: int32
    sentBorderColor*: int
    # Window info reported by River.
    appId*: string
    title*: string
    ## The window has a parent (dialog/transient); it floats.
    hasParent*: bool
    ## Preferred min/max size (river_window_v1.dimensions_hint); 0 = no preference.
    minWidth*, minHeight*, maxWidth*, maxHeight*: int
    ## parent/dimensions_hint changed; re-evaluated in the next manage sequence.
    hintsDirty*: bool
    ## Place the (floating) client in the middle of its monitor once its size is known.
    needsCenter*: bool
    ## An app rule matched and was applied.
    ruleApplied*: bool
    ## The client was already held back one manage sequence waiting for its
    ## app_id/title (see `assignUnassigned`).
    deferredForInfo*: bool
    ## When the client was first placed on a monitor (late title rules only
    ## apply shortly after).
    placedAt*: MonoTime
    ## A (new, non-empty) title arrived since the last manage sequence.
    titleChanged*: bool
    ## Requests made by the client, handled in the next manage sequence.
    fullscreenRequest*: FullscreenRequest
    pointerRequest*: PointerRequestKind
    pointerRequestSeat*: RiverSeatV1
    pointerRequestEdges*: uint32
    # What was last sent to River.
    sentFullscreen*: bool
    sentFullscreenOutput*: RiverOutputV1
    sentTiled*: bool
    ## Dimensions the window actually took (river_window_v1.dimensions).
    reportedWidth*, reportedHeight*: int

proc newClient*(window: Window, tagIDs: varargs[TagID]): Client =
  Client(
    window: window,
    tagIDs: tagIDs.toHashSet(),
    isNew: true,
    sentVisible: true, # River considers new windows shown.
    sentWidth: -1,
    sentHeight: -1
  )

# Area helper procs
proc x*(this: Client): int = this.area.x
proc `x=`*(this: Client, x: int) {.inline.} = this.area.x = x
proc y*(this: Client): int = this.area.y
proc `y=`*(this: Client, y: int) {.inline.} = this.area.y = y
proc width*(this: Client): uint = this.area.width
proc `width=`*(this: Client, width: uint) {.inline.} = this.area.width = width
proc height*(this: Client): uint = this.area.height
proc `height=`*(this: Client, height: uint) {.inline.} = this.area.height = height

proc totalWidth*(this: Client): int {.inline.} = this.width.int + this.borderWidth.int * 2
proc totalHeight*(this: Client): int {.inline.} = this.height.int + this.borderWidth.int * 2

proc resize*(this: Client, x, y: int, width, height: uint) =
  ## Records the desired area (excluding border); applied on the next manage/render.
  this.area = (x, y, width, height)

proc setLocation*(this: Client, x, y: int) =
  this.x = x
  this.y = y

proc setUrgent*(this: Client, isUrgent: bool) =
  this.isUrgent = isUrgent

