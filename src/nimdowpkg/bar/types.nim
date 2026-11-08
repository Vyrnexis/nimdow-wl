import
  std/[tables, math],
  ../wm/area,
  ../config/configloader,
  ../config/tagsettings,
  ../wl/client as wlclient,
  ../wl/cairo,
  ../wl/cursor,
  ../wl/shm,
  ../tray/tray,
  ../wl/protocols/[river_window_management_v1, viewporter, fractional_scale_v1]

type
  ## Owns a Pango font description.
  FontDescObj* = object
    desc*: PangoFontDescription
  FontDesc* = ref FontDescObj

proc `=destroy`(f: var FontDescObj) =
  if f.desc != nil:
    pango_font_description_free(f.desc)

type
  BarTag* = object
    selected*, empty*, urgent*, hasCurrent*: bool

  BarState* = object
    tags*: seq[BarTag]
    title*, status*: string
    monitorSelected*: bool
    width*, height*: int
    ## Output scale times 120 (wp_fractional_scale units).
    scale120*: int
    visible*: bool
    configGen*: int
    ## `Tray.version` while this bar shows the tray, else -1.
    trayVersion*: int

  ## The fonts of a bar configuration: one description per configured font
  ## (for explicit font selection) and one combining the families so Pango
  ## falls back through them. Shared by the bars and the menu popups; the
  ## descriptions are freed with the last reference.
  FontSet* = ref object
    names*: seq[string]
    fonts*: seq[FontDesc]
    all*: FontDesc

  TextInfo* = object
    valid*: bool
    width*, height*: int
    ## x offset of each character from the start of the text.
    characters*: seq[int]

  ## A piece of the status with the same colors and font.
  Run* = object
    text*: string
    ## -1: default.
    fg*, bg*, font*: int
    isSeparator*: bool
    ## Index of the first character (the unit separators count as one).
    first*: int
    count*: int
    info*: TextInfo

  ParsedStatus* = object
    ## The status text this was parsed from.
    source*: string
    valid*: bool
    runs*: seq[Run]
    ## Powerline glyphs without background, see `renderStringRightAligned`.
    probe*: string

  ## Vertical extent of the colored status backgrounds.
  BlockMetrics* = object
    valid*: bool
    probe*: string
    height*, bufH*: int
    top*, size*: float

  StatusBar* = ref object
    ctx*: BarContext
    scaled*: ScaledSurface
    shell*: RiverShellSurfaceV1
    node*: RiverNodeV1
    settings*: BarSettings
    tagSettings*: TagSettings
    ## What should be shown, and what is shown right now.
    wanted*, drawn*: BarState
    configGen*: int
    fonts*: FontSet
    fontErrorLogged*: bool
    pool*: ShmPool
    parsed*: ParsedStatus
    ## Text measurements are valid for this config generation and scale.
    metricsGen*, metricsScale*: int
    tagInfos*: seq[TextInfo]
    blockMetrics*: BlockMetrics
    # Drawing context, only valid while drawing.
    cr*: Cairo
    clickables*: seq[tuple[start: int, stop: int, characters: seq[int]]]
    tray*: Tray
    ## The tray icons as drawn last (surface coordinates), see `trayLayout`.
    trayRegions*: seq[TrayRegion]
    ## Position of the bar on the screen, from the last `flush`.
    originX*, originY*: int

  TrayRegion* = object
    uid*: int
    id*: string
    status*: ItemStatus
    hasIcon*: bool
    ## Where the icon came from (file path or pixmap summary).
    icon*: string
    ## Logical x of the icon in the bar, and its width (= height).
    x*, width*: int

  ClickedRegion* = object
    regionID*: int
    width*: int
    index*: int
    regionCord*: Point[int]
    clickCord*: Point[int]

  BarClick* = object
    bar*: StatusBar
    x*, y*: int
    ## 1 left, 2 middle, 3 right, 4 scroll up, 5 scroll down.
    button*: int

  ## A non-bar surface (a menu popup) that receives the pointer events of
  ## its `surface`. Positions are surface coordinates; `button` gets X11 style
  ## button numbers (1 left, 2 middle, 3 right).
  InputTarget* = ref object
    surface*: WlSurface
    ## Scale (x120) used for the cursor image.
    scale120*: int
    enter*, motion*: proc(x, y: int) {.closure.}
    button*: proc(button, x, y: int) {.closure.}
    leave*: proc() {.closure.}

  BarPointer* = ref object
    obj*: WlPointer
    ctx*: BarContext
    focus*: StatusBar
    target*: InputTarget
    x*, y*: int
    version*: uint32
    ## Scroll state: accumulated pixel-like axis value, accumulated wheel
    ## notches (x120), and what the current frame carries.
    axisAcc*: float
    wheelAcc*: int
    frameAxis*: float
    frameWheel*: int
    frameHasWheel*: bool

  BarContext* = ref object
    compositor*: WlCompositor
    shm*: WlShm
    manager*: RiverWindowManagerV1
    viewporter*: WpViewporter
    fractionalManager*: WpFractionalScaleManagerV1
    ## Popup surfaces that get pointer input (see `InputTarget`).
    targets*: seq[InputTarget]
    ## Called with every wl_keyboard created for a seat (the menu popup adds
    ## its listener there).
    onKeyboard*: proc(keyboard: WlKeyboard) {.closure.}
    ## The pointer moved over a bar (surface coordinates) / left it.
    barHover*: proc(bar: StatusBar, x, y: int) {.closure.}
    barLeave*: proc() {.closure.}
    # Pointer cursor
    cursorSurface*: WlSurface
    ## Loaded cursor themes by integer scale.
    cursorThemes*: Table[int, WlCursorTheme]
    pointers*: seq[BarPointer]
    ## All bars, to find the one a pointer entered.
    bars*: seq[StatusBar]
    fontCache*: FontSet
    clicks*: seq[BarClick]
    requestManage*: proc() {.closure.}
