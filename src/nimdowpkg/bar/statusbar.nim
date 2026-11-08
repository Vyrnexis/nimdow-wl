## The built-in status bar: a `river_shell_surface_v1` per monitor, drawn with
## cairo + pango into a double-buffered wl_shm pool.
##
## Input: the shell surface receives wl_pointer events directly on our own
## connection (we bind wl_seat and its pointer). Button presses and scrolls over
## a bar are queued in `BarContext.clicks` and handled by the window manager in
## the next manage sequence (a manage sequence is requested via
## `requestManage`, since pointer events do not start one by themselves).
##
## All bar commits happen in `flush`, which must only be called during a manage
## or render sequence (the commit is synchronised with `sync_next_commit`).
##
## Scale: with wp_fractional_scale_v1 + wp_viewporter the buffer is rendered at
## the physical size and the viewport destination is the logical size. Without
## them the integer wl_surface.preferred_buffer_scale is used with
## set_buffer_scale. Drawing code always works in logical units (the cairo
## surface has a device scale).
##
## A cursor image (wayland-cursor, XCURSOR_THEME/XCURSOR_SIZE) is set while the
## pointer is over a bar.

import
  std/[unicode, strutils, tables, os, math, sequtils]

import
  ../wm/area,
  ../sys/logger,
  ../config/configloader,
  ../config/tagsettings,
  ../wl/client as wlclient,
  ../wl/cairo,
  ../wl/cursor,
  ../wl/shm,
  ../tray/tray,
  ../wl/protocols/[river_window_management_v1, viewporter, fractional_scale_v1]

const
  boxWidth = 4
  rightPadding = 4
  btnLeft = 0x110'u32
  btnRight = 0x111'u32
  btnMiddle = 0x112'u32
  ## X11 style button numbers, as passed to the click region commands.
  buttonLeft = 1
  buttonMiddle = 2
  buttonRight = 3
  buttonScrollUp = 4
  buttonScrollDown = 5
  scrollThreshold = 10.0
  ## wl_pointer.axis_value120 units of one wheel notch.
  wheelNotch = 120
  ## wl_pointer versions that send frame/axis_stop and axis_value120.
  pointerFrameVersion = 5'u32
  pointerValue120Version = 8'u32
  seatVersion = 8'u32

type
  ## Owns a Pango font description.
  FontDescObj = object
    desc: PangoFontDescription
  FontDesc = ref FontDescObj

proc `=destroy`(f: var FontDescObj) =
  if f.desc != nil:
    pango_font_description_free(f.desc)

type
  BarTag* = object
    selected*, empty*, urgent*, hasCurrent*: bool

  BarState = object
    tags: seq[BarTag]
    title, status: string
    monitorSelected: bool
    width, height: int
    ## Output scale times 120 (wp_fractional_scale units).
    scale120: int
    visible: bool
    configGen: int
    ## `Tray.version` while this bar shows the tray, else -1.
    trayVersion: int

  ## The fonts of a bar configuration: one description per configured font
  ## (for explicit font selection) and one combining the families so Pango
  ## falls back through them. Shared by the bars and the menu popups; the
  ## descriptions are freed with the last reference.
  FontSet* = ref object
    names: seq[string]
    fonts: seq[FontDesc]
    all: FontDesc

  TextInfo = object
    valid: bool
    width, height: int
    ## x offset of each character from the start of the text.
    characters: seq[int]

  ## A piece of the status with the same colors and font.
  Run = object
    text: string
    ## -1: default.
    fg, bg, font: int
    isSeparator: bool
    ## Index of the first character (the unit separators count as one).
    first: int
    count: int
    info: TextInfo

  ParsedStatus = object
    ## The status text this was parsed from.
    source: string
    valid: bool
    runs: seq[Run]
    ## Powerline glyphs without background, see `renderStringRightAligned`.
    probe: string

  ## Vertical extent of the colored status backgrounds.
  BlockMetrics = object
    valid: bool
    probe: string
    height, bufH: int
    top, size: float

  StatusBar* = ref object
    ctx: BarContext
    scaled: ScaledSurface
    shell: RiverShellSurfaceV1
    node*: RiverNodeV1
    settings: BarSettings
    tagSettings: TagSettings
    ## What should be shown, and what is shown right now.
    wanted, drawn: BarState
    configGen: int
    fonts: FontSet
    fontErrorLogged: bool
    pool: ShmPool
    parsed: ParsedStatus
    ## Text measurements are valid for this config generation and scale.
    metricsGen, metricsScale: int
    tagInfos: seq[TextInfo]
    blockMetrics: BlockMetrics
    # Drawing context, only valid while drawing.
    cr: Cairo
    clickables: seq[tuple[start: int, stop: int, characters: seq[int]]]
    tray: Tray
    ## The tray icons as drawn last (surface coordinates), see `trayLayout`.
    trayRegions: seq[TrayRegion]
    ## Position of the bar on the screen, from the last `flush`.
    originX, originY: int

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

  BarPointer = ref object
    obj: WlPointer
    ctx: BarContext
    focus: StatusBar
    target: InputTarget
    x, y: int
    version: uint32
    ## Scroll state: accumulated pixel-like axis value, accumulated wheel
    ## notches (x120), and what the current frame carries.
    axisAcc: float
    wheelAcc: int
    frameAxis: float
    frameWheel: int
    frameHasWheel: bool

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
    cursorSurface: WlSurface
    ## Loaded cursor themes by integer scale.
    cursorThemes: Table[int, WlCursorTheme]
    pointers: seq[BarPointer]
    ## All bars, to find the one a pointer entered.
    bars: seq[StatusBar]
    fontCache: FontSet
    clicks*: seq[BarClick]
    requestManage*: proc() {.closure.}


# ---------------------------------------------------------------------------
# Wayland globals: compositor, shm, seats/pointers
# ---------------------------------------------------------------------------

proc setCursor(p: BarPointer, serial: uint32, scale: int) =
  ## Shows the default cursor of the theme named by XCURSOR_THEME/XCURSOR_SIZE.
  let ctx = p.ctx
  if ctx.cursorSurface == nil:
    ctx.cursorSurface = wl_compositor_create_surface(ctx.compositor)
  if scale notin ctx.cursorThemes:
    # Loaded once per scale (nil when the theme cannot be loaded).
    let
      themeName = getEnv("XCURSOR_THEME")
      size = try: parseInt(getEnv("XCURSOR_SIZE", "24")) except ValueError: 24
    ctx.cursorThemes[scale] = wl_cursor_theme_load(
      if themeName.len > 0: themeName.cstring else: nil,
      (max(size, 1) * scale).cint,
      ctx.shm
    )
  let theme = ctx.cursorThemes[scale]
  if theme == nil:
    return
  var cursor = wl_cursor_theme_get_cursor(theme, "default")
  if cursor == nil:
    cursor = wl_cursor_theme_get_cursor(theme, "left_ptr")
  if cursor == nil or cursor.imageCount == 0:
    return
  let
    image = cursor.images[0]
    buffer = wl_cursor_image_get_buffer(image)
  if buffer.isNil:
    return
  wl_surface_set_buffer_scale(ctx.cursorSurface, scale.int32)
  wl_surface_attach(ctx.cursorSurface, buffer, 0, 0)
  wl_surface_damage_buffer(ctx.cursorSurface, 0, 0, image.width.int32, image.height.int32)
  wl_surface_commit(ctx.cursorSurface)
  wl_pointer_set_cursor(
    p.obj, serial, ctx.cursorSurface,
    (image.hotspotX.int div scale).int32, (image.hotspotY.int div scale).int32
  )

proc scale120*(this: StatusBar): int = this.scaled.scale120

proc resetScroll(p: BarPointer) =
  p.axisAcc = 0
  p.wheelAcc = 0
  p.frameAxis = 0
  p.frameWheel = 0
  p.frameHasWheel = false

proc pointerEnter(data: pointer, obj: WlPointer, serial: uint32, surface: WlSurface,
    x, y: WlFixed) {.cdecl.} =
  let p = cast[BarPointer](data)
  p.focus = nil
  p.target = nil
  p.x = wlFixedToFloat(x).int
  p.y = wlFixedToFloat(y).int
  p.resetScroll()
  if not surface.isNil:
    for target in p.ctx.targets:
      if target.surface == surface:
        p.target = target
        p.setCursor(serial, max(1, (target.scale120 + 119) div 120))
        if target.enter != nil:
          target.enter(p.x, p.y)
        return
    for bar in p.ctx.bars:
      if bar.scaled.surface == surface:
        p.focus = bar
        p.setCursor(serial, max(1, (bar.scale120 + 119) div 120))
        if p.ctx.barHover != nil:
          p.ctx.barHover(bar, p.x, p.y)
        return

proc pointerLeave(data: pointer, obj: WlPointer, serial: uint32,
    surface: WlSurface) {.cdecl.} =
  let p = cast[BarPointer](data)
  if p.focus != nil and p.ctx.barLeave != nil:
    p.ctx.barLeave()
  p.focus = nil
  let target = p.target
  p.target = nil
  if target != nil and target.leave != nil:
    target.leave()

proc pointerMotion(data: pointer, obj: WlPointer, time: uint32, x, y: WlFixed) {.cdecl.} =
  let p = cast[BarPointer](data)
  p.x = wlFixedToFloat(x).int
  p.y = wlFixedToFloat(y).int
  if p.target != nil and p.target.motion != nil:
    p.target.motion(p.x, p.y)
  elif p.focus != nil and p.ctx.barHover != nil:
    p.ctx.barHover(p.focus, p.x, p.y)

proc queueClick(p: BarPointer, button: int) =
  if p.target != nil:
    if p.target.button != nil:
      p.target.button(button, p.x, p.y)
    return
  if p.focus == nil:
    return
  p.ctx.clicks.add BarClick(bar: p.focus, x: p.x, y: p.y, button: button)
  if p.ctx.requestManage != nil:
    p.ctx.requestManage()

proc pointerButton(data: pointer, obj: WlPointer, serial, time, button,
    state: uint32) {.cdecl.} =
  if state != WL_POINTER_BUTTON_STATE_PRESSED:
    return
  let x11Button =
    case button
    of btnLeft: buttonLeft
    of btnMiddle: buttonMiddle
    of btnRight: buttonRight
    else: 0
  if x11Button != 0:
    queueClick(cast[BarPointer](data), x11Button)

proc scrollSteps(p: BarPointer) =
  ## Queues the scroll clicks of what accumulated so far. Wheel notches
  ## (axis_value120) count 120 per click; everything else (touchpads, wheels of
  ## compositors without value120) is the accumulated axis value, a click per
  ## `scrollThreshold`.
  if p.frameHasWheel:
    p.wheelAcc += p.frameWheel
    while p.wheelAcc <= -wheelNotch:
      p.wheelAcc += wheelNotch
      queueClick(p, buttonScrollUp)
    while p.wheelAcc >= wheelNotch:
      p.wheelAcc -= wheelNotch
      queueClick(p, buttonScrollDown)
  else:
    p.axisAcc += p.frameAxis
    if p.axisAcc <= -scrollThreshold:
      p.axisAcc = 0
      queueClick(p, buttonScrollUp)
    elif p.axisAcc >= scrollThreshold:
      p.axisAcc = 0
      queueClick(p, buttonScrollDown)
  p.frameAxis = 0
  p.frameWheel = 0
  p.frameHasWheel = false

proc pointerAxis(data: pointer, obj: WlPointer, time: uint32, axis: uint32,
    value: WlFixed) {.cdecl.} =
  if axis != WL_POINTER_AXIS_VERTICAL_SCROLL:
    return
  let p = cast[BarPointer](data)
  p.frameAxis += wlFixedToFloat(value)
  if p.version < pointerFrameVersion:
    # No frame events: handle every event on its own.
    p.scrollSteps()

proc pointerAxisValue120(data: pointer, obj: WlPointer, axis: uint32,
    value120: int32) {.cdecl.} =
  if axis != WL_POINTER_AXIS_VERTICAL_SCROLL:
    return
  let p = cast[BarPointer](data)
  p.frameWheel += value120.int
  p.frameHasWheel = true

proc pointerAxisStop(data: pointer, obj: WlPointer, time: uint32, axis: uint32) {.cdecl.} =
  ## The scroll gesture ended: what is left of it must not count toward the next.
  if axis != WL_POINTER_AXIS_VERTICAL_SCROLL:
    return
  let p = cast[BarPointer](data)
  p.axisAcc = 0
  p.wheelAcc = 0

proc pointerFrame(data: pointer, obj: WlPointer) {.cdecl.} =
  let p = cast[BarPointer](data)
  p.scrollSteps()

var pointerListener = wl_pointer_noop_listener()
pointerListener.enter = pointerEnter
pointerListener.leave = pointerLeave
pointerListener.motion = pointerMotion
pointerListener.button = pointerButton
pointerListener.axis = pointerAxis
pointerListener.axis_value120 = pointerAxisValue120
pointerListener.axis_stop = pointerAxisStop
pointerListener.frame = pointerFrame

type SeatData = ref object
  ctx: BarContext
  seat: WlSeat
  pointer: BarPointer
  keyboard: WlKeyboard

proc seatCapabilities(data: pointer, seat: WlSeat, caps: uint32) {.cdecl.} =
  let s = cast[SeatData](data)
  if (caps and WL_SEAT_CAPABILITY_POINTER) != 0 and s.pointer == nil:
    let p = BarPointer(ctx: s.ctx, obj: wl_seat_get_pointer(seat))
    p.version = wl_proxy_get_version(cast[ptr WlProxy](p.obj))
    GC_ref p
    discard wl_pointer_add_listener(p.obj, addr pointerListener, cast[pointer](p))
    s.pointer = p
    s.ctx.pointers.add p
  elif (caps and WL_SEAT_CAPABILITY_POINTER) == 0 and s.pointer != nil:
    s.ctx.pointers.delete s.ctx.pointers.find(s.pointer)
    wl_pointer_release(s.pointer.obj)
    GC_unref s.pointer
    s.pointer = nil
  if (caps and WL_SEAT_CAPABILITY_KEYBOARD) != 0 and s.keyboard.isNil:
    s.keyboard = wl_seat_get_keyboard(seat)
    if s.ctx.onKeyboard != nil:
      s.ctx.onKeyboard(s.keyboard)
  elif (caps and WL_SEAT_CAPABILITY_KEYBOARD) == 0 and not s.keyboard.isNil:
    wl_keyboard_release(s.keyboard)
    s.keyboard = nil

var seatListener = wl_seat_noop_listener()
seatListener.capabilities = seatCapabilities

proc bindSeat(ctx: BarContext, registry: Registry, global: Global) =
  let s = SeatData(ctx: ctx)
  GC_ref s
  s.seat = bindGlobal[WlSeat](registry, global, wl_seat_interface, seatVersion)
  discard wl_seat_add_listener(s.seat, addr seatListener, cast[pointer](s))

proc newBarContext*(registry: Registry, manager: RiverWindowManagerV1): BarContext =
  ## Binds wl_compositor, wl_shm and all wl_seats. Returns nil when the
  ## compositor or shm is missing (the bar is then unavailable).
  let
    compositorGlobal = registry.find("wl_compositor")
    shmGlobal = registry.find("wl_shm")
  if compositorGlobal.version < 4 or shmGlobal.version < 1:
    return nil
  result = BarContext(manager: manager)
  # Version 6 adds wl_surface.preferred_buffer_scale.
  result.compositor = bindGlobal[WlCompositor](
    registry, compositorGlobal, wl_compositor_interface, 6
  )
  result.shm = bindGlobal[WlShm](registry, shmGlobal, wl_shm_interface, 1)
  let
    viewporterGlobal = registry.find("wp_viewporter")
    fractionalGlobal = registry.find("wp_fractional_scale_manager_v1")
  if viewporterGlobal.version >= 1 and fractionalGlobal.version >= 1:
    result.viewporter = bindGlobal[WpViewporter](
      registry, viewporterGlobal, wp_viewporter_interface, 1
    )
    result.fractionalManager = bindGlobal[WpFractionalScaleManagerV1](
      registry, fractionalGlobal, wp_fractional_scale_manager_v1_interface, 1
    )
  for global in registry.globals:
    if global.iface == "wl_seat":
      result.bindSeat(registry, global)
  # Seats added later get the pointer handling too.
  let ctx = result
  registry.onGlobal = proc(global: Global) =
    if global.iface == "wl_seat":
      ctx.bindSeat(registry, global)

# ---------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------

proc xftToPango(font: string): tuple[families, style, size: string] =
  ## Converts an Xft/fontconfig name ("monospace:size=10:bold") or an XLFD to
  ## pieces of a Pango font description.
  result.size = ""
  if font.startsWith("-"):
    # XLFD: -foundry-family-weight-slant-width-style-pixels-points-...
    let parts = font.split('-')
    if parts.len > 7:
      result.families = parts[2]
      if parts[3].toLowerAscii in ["bold", "demibold"]: result.style.add " Bold"
      if parts[4].toLowerAscii in ["i", "o"]: result.style.add " Italic"
      if parts[7].len > 0 and parts[7] != "*" and parts[7] != "0":
        result.size = parts[7] & "px"
    return
  let parts = font.split(':')
  result.families = parts[0].strip()
  for opt in parts[1 .. ^1]:
    let kv = opt.split('=', maxsplit = 1)
    let key = kv[0].strip().toLowerAscii()
    let value = if kv.len > 1: kv[1].strip() else: ""
    case key
    of "size": result.size = value
    of "pixelsize": result.size = value & "px"
    of "bold": result.style.add " Bold"
    of "italic": result.style.add " Italic"
    of "weight":
      if value.toLowerAscii in ["bold", "demibold", "black", "extrabold", "200"]:
        result.style.add " Bold"
    of "slant":
      if value.toLowerAscii in ["italic", "oblique", "100", "110"]:
        result.style.add " Italic"
    of "style":
      for word in value.split({' ', ','}):
        if word.len > 0 and word.toLowerAscii notin ["regular", "normal", "book"]:
          result.style.add " " & word
    else: discard

proc toPangoString(font: string): string =
  let (families, style, size) = xftToPango(font)
  let family = if families.len == 0: "monospace" else: families
  result = family & "," & style & " " & (if size.len == 0: "10" else: size)

proc newFontDesc(spec: string): FontDesc =
  FontDesc(desc: pango_font_description_from_string(spec.cstring))

proc allFonts*(fonts: FontSet): PangoFontDescription =
  ## The description that falls back through all the configured families.
  fonts.all.desc

proc buildFontSet(names: seq[string]): FontSet =
  ## One description per configured font (for explicit font selection) and one
  ## combining all families so Pango falls back through them.
  result = FontSet(names: names)
  var
    families: seq[string]
    style, size: string
  for font in names:
    result.fonts.add newFontDesc(toPangoString(font))
    let parts = xftToPango(font)
    if parts.families.len > 0:
      families.add parts.families
    if families.len == 1:
      style = parts.style
      size = parts.size
  if families.len == 0:
    families.add "monospace"
  # Only the first family: listing an emoji font (e.g. Noto Color Emoji, the
  # default config's second font) makes Pango draw ASCII digits with its
  # keycap glyphs. Fontconfig's own fallback still finds emoji/icon glyphs.
  let combined = families[0] & "," & style & " " & (if size.len == 0: "10" else: size)
  result.all = newFontDesc(combined)
  if result.fonts.len == 0:
    result.fonts.add newFontDesc("monospace 10")

proc fontSetFor(ctx: BarContext, names: seq[string]): FontSet =
  ## The font set of a configuration, built once and shared by all bars (and
  ## the menu popups) using the same fonts.
  if ctx.fontCache == nil or ctx.fontCache.names != names:
    ctx.fontCache = buildFontSet(names)
  ctx.fontCache

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newStatusBar*(
  ctx: BarContext,
  settings: BarSettings,
  tagSettings: TagSettings
): StatusBar =
  result = StatusBar(
    ctx: ctx, settings: settings, tagSettings: tagSettings,
    metricsGen: -1, metricsScale: -1
  )
  result.wanted.trayVersion = -1
  result.drawn.trayVersion = -1
  GC_ref result
  let bar = result
  result.scaled = newScaledSurface(
    ctx.compositor, ctx.viewporter, ctx.fractionalManager, 120,
    proc() =
      # Redrawn in the next manage sequence.
      if ctx.requestManage != nil:
        ctx.requestManage()
  )
  result.pool = newShmPool(ctx.shm, "nimdow-bar", proc() =
    if ctx.requestManage != nil:
      ctx.requestManage()
  )
  result.shell = river_window_manager_v1_get_shell_surface(ctx.manager, result.scaled.surface)
  result.node = river_shell_surface_v1_get_node(result.shell)
  result.fonts = ctx.fontSetFor(settings.fonts)
  ctx.bars.add bar

proc destroy*(ctx: BarContext) =
  ## Releases the cursor surface and themes. The bars must be destroyed first;
  ## the context must not be used afterwards.
  for theme in ctx.cursorThemes.values:
    if theme != nil:
      wl_cursor_theme_destroy(theme)
  ctx.cursorThemes.clear()
  if ctx.cursorSurface != nil:
    wl_surface_destroy(ctx.cursorSurface)
    ctx.cursorSurface = nil

proc removeTarget*(ctx: BarContext, target: InputTarget) =
  ## Stops routing pointer events to the target (its surface is going away).
  let index = ctx.targets.find(target)
  if index >= 0:
    ctx.targets.delete index
  for pointer in ctx.pointers:
    if pointer.target == target:
      pointer.target = nil

proc destroy*(this: StatusBar) =
  ## Releases the bar's Wayland objects. The bar must not be used afterwards.
  for pointer in this.ctx.pointers:
    if pointer.focus == this:
      pointer.focus = nil
  var i = 0
  while i < this.ctx.clicks.len:
    if this.ctx.clicks[i].bar == this:
      this.ctx.clicks.delete i
    else:
      inc i
  let index = this.ctx.bars.find(this)
  if index >= 0:
    this.ctx.bars.delete index
  this.pool.destroy()
  river_node_v1_destroy(this.node)
  river_shell_surface_v1_destroy(this.shell)
  this.scaled.destroy()
  GC_unref this

proc setConfig*(this: StatusBar, settings: BarSettings, tagSettings: TagSettings) =
  this.settings = settings
  this.tagSettings = tagSettings
  this.fonts = this.ctx.fontSetFor(settings.fonts)
  inc this.configGen

proc height*(this: StatusBar): int = this.settings.height.int

proc barSettings*(this: StatusBar): BarSettings = this.settings

proc fontSet*(this: StatusBar): FontSet =
  ## The bar's fonts (shared; keep the reference to keep using them).
  this.fonts

proc origin*(this: StatusBar): tuple[x, y: int] = (this.originX, this.originY)

proc update*(this: StatusBar, tags: seq[BarTag], title: string, monitorSelected: bool) =
  ## Sets what the bar shows for tags and the focused window; drawn by `flush`.
  this.wanted.tags = tags
  this.wanted.title = title
  this.wanted.monitorSelected = monitorSelected

proc setTray*(this: StatusBar, tray: Tray) =
  ## Shows the tray on this bar (nil: no tray here).
  this.tray = tray
  this.wanted.trayVersion = if tray != nil: tray.version else: -1

proc trayLayout*(this: StatusBar): seq[TrayRegion] =
  ## The icons of the last draw, with x relative to the screen.
  for region in this.trayRegions:
    var r = region
    r.x += this.originX
    result.add r

proc trayIconAt*(this: StatusBar, x, y: int): tuple[uid, x, y: int] =
  ## The tray icon under the surface position (uid -1: none), with the icon's
  ## position on the screen.
  result = (-1, 0, 0)
  for region in this.trayRegions:
    if x >= region.x and x < region.x + region.width and y >= 0 and y < this.wanted.height:
      return (region.uid, this.originX + region.x,
        this.originY + (this.wanted.height - region.width) div 2)

proc setStatus*(this: StatusBar, status: string) =
  this.wanted.status = status

proc status*(this: StatusBar): string = this.wanted.status

proc tagCount*(this: StatusBar): int = this.tagSettings.len


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

type Color = tuple[r, g, b, a: float]

proc toColor(hex: int, alpha: uint8 = 255): Color =
  (
    ((hex shr 16) and 0xff).float / 255,
    ((hex shr 8) and 0xff).float / 255,
    (hex and 0xff).float / 255,
    alpha.float / 255
  )

proc fillRect(this: StatusBar, color: Color, x, y, w, h: int, replace = false) =
  ## `replace` writes the color as is (also its alpha) instead of blending.
  if w <= 0 or h <= 0:
    return
  if replace:
    cairo_set_operator(this.cr, CAIRO_OPERATOR_SOURCE)
  cairo_set_source_rgba(this.cr, color.r, color.g, color.b, color.a)
  cairo_rectangle(this.cr, x.cdouble, y.cdouble, w.cdouble, h.cdouble)
  cairo_fill(this.cr)
  if replace:
    cairo_set_operator(this.cr, CAIRO_OPERATOR_OVER)

proc sanitize(s: string): string =
  ## Replaces invalid UTF-8 and line breaks, which pango does not like.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in {'\n', '\r', '\t'}:
      result.add ' '
      inc i
    elif c.ord < 0x80:
      result.add c
      inc i
    else:
      let len = runeLenAt(s, i)
      if validateUtf8(s[i ..< min(s.len, i + len)]) == -1 and len > 1:
        result.add s[i ..< i + len]
        i += len
      else:
        result.add '?'
        inc i

proc newLayout(this: StatusBar, text: string, desc: PangoFontDescription,
    ellipsizeWidth = -1): PangoLayout =
  ## `ellipsizeWidth` >= 0: the text is ellipsized to that many logical pixels.
  result = pango_cairo_create_layout(this.cr)
  pango_layout_set_font_description(result, desc)
  pango_layout_set_text(result, text.cstring, text.len.cint)
  if ellipsizeWidth >= 0:
    pango_layout_set_width(result, (ellipsizeWidth * PANGO_SCALE).cint)
    pango_layout_set_ellipsize(result, PANGO_ELLIPSIZE_END)

proc measure(layout: PangoLayout, text: string): TextInfo =
  ## Size of the laid out text and the x offset of each of its characters.
  var w, h: cint
  pango_layout_get_pixel_size(layout, addr w, addr h)
  result.valid = true
  result.width = w
  result.height = h
  result.characters = newSeqOfCap[int](text.len)
  var i = 0
  while i < text.len:
    var rect: PangoRectangle
    pango_layout_index_to_pos(layout, i.cint, addr rect)
    result.characters.add rect.x div PANGO_SCALE
    i += max(1, runeLenAt(text, i))

proc drawLayout(this: StatusBar, layout: PangoLayout, height, x: int, color: Color) =
  ## Draws an already laid out text of the given height at x, vertically
  ## centered in the bar.
  cairo_set_source_rgba(this.cr, color.r, color.g, color.b, color.a)
  cairo_move_to(this.cr, x.cdouble, ((this.wanted.height - height) div 2).cdouble)
  pango_cairo_show_layout(this.cr, layout)

# Colors for ANSI CSI SGR coloration
const
  basicColors = [0x000000, 0xcd0000, 0x00cd00, 0xcdcd00,
                 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5]
  brightColors = [0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00,
                  0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff]
  extraColors = [0x000000, 0x800000, 0x008000, 0x808000,
                 0x000080, 0x800080, 0x008080, 0xc0c0c0,
                 0x808080, 0xff0000, 0x00ff00, 0xffff00,
                 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
                 0x000000, 0x00005f, 0x000087, 0x0000af,
                 0x0000d7, 0x0000ff, 0x005f00, 0x005f5f,
                 0x005f87, 0x005faf, 0x005fd7, 0x005fff,
                 0x008700, 0x00875f, 0x008787, 0x0087af,
                 0x0087d7, 0x0087ff, 0x00af00, 0x00af5f,
                 0x00af87, 0x00afaf, 0x00afd7, 0x00afff,
                 0x00d700, 0x00d75f, 0x00d787, 0x00d7af,
                 0x00d7d7, 0x00d7ff, 0x00ff00, 0x00ff5f,
                 0x00ff87, 0x00ffaf, 0x00ffd7, 0x00ffff,
                 0x5f0000, 0x5f005f, 0x5f0087, 0x5f00af,
                 0x5f00d7, 0x5f00ff, 0x5f5f00, 0x5f5f5f,
                 0x5f5f87, 0x5f5faf, 0x5f5fd7, 0x5f5fff,
                 0x5f8700, 0x5f875f, 0x5f8787, 0x5f87af,
                 0x5f87d7, 0x5f87ff, 0x5faf00, 0x5faf5f,
                 0x5faf87, 0x5fafaf, 0x5fafd7, 0x5fafff,
                 0x5fd700, 0x5fd75f, 0x5fd787, 0x5fd7af,
                 0x5fd7d7, 0x5fd7ff, 0x5fff00, 0x5fff5f,
                 0x5fff87, 0x5fffaf, 0x5fffd7, 0x5fffff,
                 0x870000, 0x87005f, 0x870087, 0x8700af,
                 0x8700d7, 0x8700ff, 0x875f00, 0x875f5f,
                 0x875f87, 0x875faf, 0x875fd7, 0x875fff,
                 0x878700, 0x87875f, 0x878787, 0x8787af,
                 0x8787d7, 0x8787ff, 0x87af00, 0x87af5f,
                 0x87af87, 0x87afaf, 0x87afd7, 0x87afff,
                 0x87d700, 0x87d75f, 0x87d787, 0x87d7af,
                 0x87d7d7, 0x87d7ff, 0x87ff00, 0x87ff5f,
                 0x87ff87, 0x87ffaf, 0x87ffd7, 0x87ffff,
                 0xaf0000, 0xaf005f, 0xaf0087, 0xaf00af,
                 0xaf00d7, 0xaf00ff, 0xaf5f00, 0xaf5f5f,
                 0xaf5f87, 0xaf5faf, 0xaf5fd7, 0xaf5fff,
                 0xaf8700, 0xaf875f, 0xaf8787, 0xaf87af,
                 0xaf87d7, 0xaf87ff, 0xafaf00, 0xafaf5f,
                 0xafaf87, 0xafafaf, 0xafafd7, 0xafafff,
                 0xafd700, 0xafd75f, 0xafd787, 0xafd7af,
                 0xafd7d7, 0xafd7ff, 0xafff00, 0xafff5f,
                 0xafff87, 0xafffaf, 0xafffd7, 0xafffff,
                 0xd70000, 0xd7005f, 0xd70087, 0xd700af,
                 0xd700d7, 0xd700ff, 0xd75f00, 0xd75f5f,
                 0xd75f87, 0xd75faf, 0xd75fd7, 0xd75fff,
                 0xd78700, 0xd7875f, 0xd78787, 0xd787af,
                 0xd787d7, 0xd787ff, 0xd7af00, 0xd7af5f,
                 0xd7af87, 0xd7afaf, 0xd7afd7, 0xd7afff,
                 0xd7d700, 0xd7d75f, 0xd7d787, 0xd7d7af,
                 0xd7d7d7, 0xd7d7ff, 0xd7ff00, 0xd7ff5f,
                 0xd7ff87, 0xd7ffaf, 0xd7ffd7, 0xd7ffff,
                 0xff0000, 0xff005f, 0xff0087, 0xff00af,
                 0xff00d7, 0xff00ff, 0xff5f00, 0xff5f5f,
                 0xff5f87, 0xff5faf, 0xff5fd7, 0xff5fff,
                 0xff8700, 0xff875f, 0xff8787, 0xff87af,
                 0xff87d7, 0xff87ff, 0xffaf00, 0xffaf5f,
                 0xffaf87, 0xffafaf, 0xffafd7, 0xffafff,
                 0xffd700, 0xffd75f, 0xffd787, 0xffd7af,
                 0xffd7d7, 0xffd7ff, 0xffff00, 0xffff5f,
                 0xffff87, 0xffffaf, 0xffffd7, 0xffffff,
                 0x080808, 0x121212, 0x1c1c1c, 0x262626,
                 0x303030, 0x3a3a3a, 0x444444, 0x4e4e4e,
                 0x585858, 0x626262, 0x6c6c6c, 0x767676,
                 0x808080, 0x8a8a8a, 0x949494, 0x9e9e9e,
                 0xa8a8a8, 0xb2b2b2, 0xbcbcbc, 0xc6c6c6,
                 0xd0d0d0, 0xdadada, 0xe4e4e4, 0xeeeeee]
  resetCode = 0
  fontStart = 10
  fontStop = 20
  fgColorStart = 30
  fgColorStop = 37
  fgColorReset = 39
  bgColorStart = 40
  bgColorStop = 47
  bgColorReset = 49
  fgBrightColorStart = 90
  fgBrightColorStop = 97
  bgBrightColorStart = 100
  bgBrightColorStop = 107
  fgColorTable = 38
  bgColorTable = 48
  eightBitColor = 5
  twentyfourBitColor = 2
  escape = 0x1B
  finalByteRange = 0x40..0x7E
  unitSeparator = 0x1F

proc fontFor(this: StatusBar, index: int): PangoFontDescription =
  if index == -1:
    return this.fonts.allFonts
  if index > this.fonts.fonts.high:
    if not this.fontErrorLogged:
      log "Unable to select font " & $index &
        ", too few fonts defined in config.", lvlError
      this.fontErrorLogged = true
    return this.fonts.allFonts
  return this.fonts.fonts[index].desc

proc parseStatus(this: StatusBar, str: string): ParsedStatus =
  ## Splits the status into runs of the same colors and font. Supports ANSI CSI
  ## SGR colors and font selection, and the unit separator which splits the
  ## status into clickable regions.
  result.valid = true
  const maxParams = 32
  var
    color = -1
    bgColor = -1
    selectedFont = -1
    parsingCsi = false
    parsingSgr = false
    invalidSgr = false
    sgr: array[maxParams, int]
    sgrLen = 0
    ## The number being read: -1 none yet, -2 not a number.
    param = -1
    cell = 0
    i = 0

  template addSgr() =
    if param == -1:
      if sgrLen < maxParams:
        sgr[sgrLen] = 0
        inc sgrLen
    elif param == -2:
      invalidSgr = true
    elif sgrLen < maxParams:
      sgr[sgrLen] = param
      inc sgrLen
    param = -1

  while i < str.len:
    let start = i
    var rune: Rune
    fastRuneAt(str, i, rune, true)
    if rune.int32 == escape:
      parsingCsi = true
      parsingSgr = false
      invalidSgr = false
      continue
    if parsingCsi:
      if parsingSgr:
        if rune.int32 != ord(';') and rune.int32 notin finalByteRange:
          if param == -2 or rune.int32 < ord('0') or rune.int32 > ord('9'):
            param = -2
          else:
            param = max(param, 0) * 10 + (rune.int32 - ord('0'))
            if param > 100_000:
              param = -2
        else:
          addSgr()
      if rune.int32 == ord('['):
        parsingSgr = true
        sgrLen = 0
        param = -1
        continue
    if not parsingCsi:
      if rune.int32 == unitSeparator:
        result.runs.add Run(isSeparator: true, first: cell, count: 1)
      elif result.runs.len > 0 and not result.runs[^1].isSeparator and
          result.runs[^1].fg == color and result.runs[^1].bg == bgColor and
          result.runs[^1].font == selectedFont:
        result.runs[^1].text.add str[start ..< i]
        inc result.runs[^1].count
      else:
        result.runs.add Run(
          text: str[start ..< i], fg: color, bg: bgColor, font: selectedFont,
          first: cell, count: 1
        )
      inc cell
    if parsingCsi:
      if rune.int32 in finalByteRange:
        parsingCsi = false
        if parsingSgr:
          if not invalidSgr:
            var k = 0
            while k < sgrLen:
              if sgr[k] == resetCode:
                color = -1
                bgColor = -1
                selectedFont = -1
                this.fontErrorLogged = false
              elif sgr[k] >= fontStart and sgr[k] <= fontStop:
                selectedFont = sgr[k] - fontStart - 1
                this.fontErrorLogged = false
              elif sgr[k] >= fgColorStart and sgr[k] <= fgColorStop:
                color = basicColors[sgr[k] - fgColorStart]
              elif sgr[k] >= bgColorStart and sgr[k] <= bgColorStop:
                bgColor = basicColors[sgr[k] - bgColorStart]
              elif sgr[k] >= fgBrightColorStart and sgr[k] <= fgBrightColorStop:
                color = brightColors[sgr[k] - fgBrightColorStart]
              elif sgr[k] >= bgBrightColorStart and sgr[k] <= bgBrightColorStop:
                bgColor = brightColors[sgr[k] - bgBrightColorStart]
              elif sgr[k] == fgColorReset:
                color = -1
              elif sgr[k] == bgColorReset:
                bgColor = -1
              elif sgrLen > k + 2 and sgr[k] in {fgColorTable, bgColorTable} and
                  sgr[k + 1] == eightBitColor:
                let index = sgr[k + 2]
                if index in extraColors.low .. extraColors.high:
                  if sgr[k] == fgColorTable:
                    color = extraColors[index]
                  else:
                    bgColor = extraColors[index]
                k += 2
              elif sgrLen > k + 4 and sgr[k] in {fgColorTable, bgColorTable} and
                  sgr[k + 1] == twentyfourBitColor:
                let rgb = ((sgr[k + 2] and 0xff) shl 16) or
                  ((sgr[k + 3] and 0xff) shl 8) or (sgr[k + 4] and 0xff)
                if sgr[k] == fgColorTable:
                  color = rgb
                else:
                  bgColor = rgb
                k += 4
              inc k

  # Powerline glyphs (U+E0A0..U+E0D7) without a background of their own.
  for run in result.runs:
    if run.bg == -1 and not run.isSeparator:
      for rune in run.text.runes:
        if rune.int32 in 0xE0A0'i32 .. 0xE0D7'i32 and $rune notin result.probe:
          result.probe.add $rune

proc blockMetricsFor(this: StatusBar, probe: string): BlockMetrics =
  ## Vertical extent of the colored backgrounds, from the ink of `probe`.
  ## Cached per config generation and scale (`checkMetrics`).
  let cached = this.blockMetrics
  if cached.valid and cached.probe == probe and cached.height == this.wanted.height and
      cached.bufH == this.pool.height:
    return cached
  result = BlockMetrics(
    valid: true, probe: probe, height: this.wanted.height, bufH: this.pool.height
  )
  let layout = this.newLayout(probe, this.fonts.allFonts)
  var
    ink, logical: PangoRectangle
    pixelW, logicalH: cint
  pango_layout_get_extents(layout, addr ink, addr logical)
  pango_layout_get_pixel_size(layout, addr pixelW, addr logicalH)
  g_object_unref(layout)
  if ink.height > 0:
    let
      # Same vertical position as drawLayout uses.
      textTop = ((this.wanted.height - logicalH) div 2).float
      top = textTop + ink.y.float / PANGO_SCALE
      bottom = top + ink.height.float / PANGO_SCALE
      sy = if this.wanted.height > 0: this.pool.height.float / this.wanted.height.float
        else: 1.0
      snappedTop = max(0.0, floor(top * sy) / sy)
      snappedBottom = min(this.wanted.height.float, ceil(bottom * sy) / sy)
    result.top = snappedTop
    result.size = snappedBottom - snappedTop
  this.blockMetrics = result

proc checkMetrics(this: StatusBar) =
  ## Drops the cached measurements when the config or the scale changed.
  if this.metricsGen == this.wanted.configGen and this.metricsScale == this.wanted.scale120:
    return
  this.metricsGen = this.wanted.configGen
  this.metricsScale = this.wanted.scale120
  this.tagInfos.setLen 0
  this.blockMetrics.valid = false
  for run in this.parsed.runs.mitems:
    run.info.valid = false

proc renderStringRightAligned(
  this: StatusBar,
  defaultColor: Color,
  x, minX: int,
  leftPadding: Natural = 0
): int {.discardable.} =
  ## Renders the parsed status right aligned to position x and records its
  ## clickable regions. The first `leftPadding` characters are not clickable.
  ## Nothing is drawn (or clickable) left of `minX`: a status that is too wide
  ## loses its start. Returns the x position where the string starts.

  # Lay out each run once; the same layouts are drawn below.
  var
    layouts = newSeq[PangoLayout](this.parsed.runs.len)
    stringWidth = 0
  for i, run in this.parsed.runs.mpairs:
    if run.isSeparator:
      continue
    layouts[i] = this.newLayout(run.text, this.fontFor(run.font))
    if not run.info.valid:
      run.info = measure(layouts[i], run.text)
    stringWidth += run.info.width

  # Colored backgrounds are drawn as a block lined up with the glyphs used
  # for block style statusbars. When the status uses Powerline separators
  # (U+E0A0..U+E0D7, e.g. from Nerd Fonts), the block matches their height:
  # many fonts draw them over the full line height, but their "Full block"
  # (U+2588) shorter, which left the separators sticking out of the segment.
  # Otherwise the "Full block" symbol is used.
  # The block is snapped outwards to whole physical pixels: at fractional
  # scales rounding it in logical units can leave the top or bottom pixel row
  # of a segment unpainted.
  let metrics = this.blockMetricsFor(if this.parsed.probe.len == 0: "█" else: this.parsed.probe)
  let
    blockTop = metrics.top
    blockHeight = metrics.size
    firstRegion = this.clickables.len
    overflow = stringWidth > x - minX

  if overflow:
    cairo_save(this.cr)
    cairo_rectangle(this.cr, minX.cdouble, 0, max(0, x - minX).cdouble,
      this.wanted.height.cdouble)
    cairo_clip(this.cr)

  result = x - stringWidth
  var
    xLoc = x - stringWidth
    last = xLoc
    current = xLoc
    characters: seq[int]
  for i, run in this.parsed.runs:
    if run.isSeparator:
      this.clickables.add (start: last, stop: current, characters: characters)
      last = current
      reset characters
      continue
    if run.bg != -1:
      if blockHeight <= 0:
        this.fillRect(toColor(run.bg), xLoc, 0, run.info.width, this.wanted.height, true)
      else:
        let c = toColor(run.bg)
        cairo_set_operator(this.cr, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_rgba(this.cr, c.r, c.g, c.b, c.a)
        cairo_rectangle(this.cr, xLoc.cdouble, blockTop, run.info.width.cdouble, blockHeight)
        cairo_fill(this.cr)
        cairo_set_operator(this.cr, CAIRO_OPERATOR_OVER)
    this.drawLayout(
      layouts[i], run.info.height, xLoc,
      if run.fg == -1: defaultColor else: toColor(run.fg)
    )
    g_object_unref(layouts[i])
    for k in 0 ..< run.count:
      let
        cellStart = xLoc + run.info.characters[k]
        cellStop =
          if k + 1 < run.count: xLoc + run.info.characters[k + 1]
          else: xLoc + run.info.width
        pos = run.first + k
      if pos >= leftPadding:
        characters.add(cellStart - last)
      if leftPadding > pos:
        last = cellStop
    xLoc += run.info.width
    current = xLoc
  this.clickables.add (start: last, stop: current, characters: characters)

  if overflow:
    cairo_restore(this.cr)
    # Clip the click regions the same way: starts and stops stay in order, the
    # character offsets (relative to the start) shrink with the cut part.
    for i in firstRegion ..< this.clickables.len:
      let
        region = this.clickables[i]
        start = max(region.start, minX)
        cut = start - region.start
      this.clickables[i] = (
        start: start, stop: max(region.stop, start),
        characters: region.characters.mapIt(max(0, it - cut))
      )
    result = minX

proc renderTags(this: StatusBar): int =
  # Tag rendering layout is as follows:
  # <space><box><tag text><space><space>
  # Each <space> is the same width as the <box>
  let
    bg = toColor(this.settings.bgColor, this.settings.transparency)
    urgent = toColor(this.settings.urgentColor)

  var
    pad = this.settings.tagPadding.int
    textXPos: int = pad
    i = 0
  for tagID, tagSetting in this.tagSettings.pairs():
    let state =
      if i < this.wanted.tags.len: this.wanted.tags[i]
      else: BarTag(empty: true)
    inc i

    var fgColor = toColor(this.settings.fgColor)
    if state.selected:
      fgColor = toColor(this.settings.selectionColor)
    elif not state.empty:
      fgColor = toColor(this.settings.hasWindowsColor)

    let text = sanitize(tagSetting.displayString)
    let layout = this.newLayout(text, this.fonts.allFonts)
    if this.tagInfos.len < i:
      this.tagInfos.setLen i
    if not this.tagInfos[i - 1].valid:
      this.tagInfos[i - 1] = measure(layout, text)
    let info = this.tagInfos[i - 1]

    if not state.empty:
      let boxXLoc = textXPos - pad div 2
      if state.urgent:
        this.fillRect(
          urgent, textXPos - pad, 0, info.width + pad * 2, this.wanted.height
        )
      if this.settings.showIndicator:
        this.fillRect(fgColor, boxXLoc, 0, 4, 4)
        if not state.hasCurrent:
          this.fillRect(if state.urgent: urgent else: bg, boxXLoc + 1, 1, 2, 2, true)

    this.drawLayout(layout, info.height, textXPos, fgColor)
    g_object_unref(layout)
    this.clickables.add (
      start: textXPos - pad,
      stop: textXPos + info.width + pad,
      characters: info.characters
    )
    textXPos += info.width + pad * 2

  return textXPos

proc renderTray(this: StatusBar): int =
  ## Draws the tray icons at the right edge. Returns the x position where the
  ## tray starts (the right edge when there are no icons).
  result = this.wanted.width - rightPadding
  this.trayRegions.setLen 0
  if this.wanted.trayVersion < 0 or this.tray == nil:
    return
  let
    items = this.tray.visibleItems()
    padding = max(0, this.settings.trayIconPadding.int)
    spacing = max(0, this.settings.trayIconSpacing.int)
    size = max(1, this.wanted.height - 2 * padding)
    pixels = max(1, (size * this.scale120 + 60) div 120)
  if items.len == 0:
    return
  var x = this.wanted.width - rightPadding - (items.len * size + (items.len - 1) * spacing)
  result = x - spacing
  let y = (this.wanted.height - size) div 2
  for item in items:
    let (surface, real, desc) = item.iconSurface(pixels)
    if surface != nil:
      cairo_save(this.cr)
      cairo_translate(this.cr, x.cdouble, y.cdouble)
      cairo_scale(this.cr, size.float / pixels.float, size.float / pixels.float)
      cairo_set_source_surface(this.cr, surface, 0, 0)
      cairo_paint(this.cr)
      cairo_restore(this.cr)
    else:
      # No icon: the first letter of the id or title in a box.
      let
        fg = toColor(this.settings.fgColor)
        label = (if item.id.len > 0: item.id else: item.title).strip()
      this.fillRect((fg.r, fg.g, fg.b, 0.35), x, y, size, size)
      if label.len > 0:
        let letter = sanitize($label.runeAt(0)).toUpper()
        let layout = this.newLayout(letter, this.fonts.allFonts)
        var w, h: cint
        pango_layout_get_pixel_size(layout, addr w, addr h)
        cairo_set_source_rgba(this.cr, fg.r, fg.g, fg.b, fg.a)
        cairo_move_to(this.cr, (x + (size - w) div 2).cdouble, (y + (size - h) div 2).cdouble)
        pango_cairo_show_layout(this.cr, layout)
        g_object_unref(layout)
    this.trayRegions.add TrayRegion(
      uid: item.uid, id: item.id, status: item.status, hasIcon: real, icon: desc, x: x, width: size
    )
    x += size + spacing

proc renderStatus(this: StatusBar, rightEdge, minX: int): int =
  ## Returns the x position where the status starts.
  result = rightEdge
  if this.wanted.status.len > 0:
    # Two non-clickable padding characters in front of the status.
    const padding = 2
    if not this.parsed.valid or this.parsed.source != this.wanted.status:
      # Parsed once per status text, not on every redraw.
      this.parsed = this.parseStatus(' '.repeat(padding) & sanitize(this.wanted.status))
      this.parsed.source = this.wanted.status
    result = this.renderStringRightAligned(
      toColor(this.settings.fgColor), rightEdge, minX, padding
    )

proc renderActiveWindowTitle(this: StatusBar, minRenderX, maxRenderX: int) =
  ## Draws the title between the tags and the status, ellipsized to fit.
  let title = sanitize(this.wanted.title)
  let available = maxRenderX - minRenderX
  if title.len <= 0 or available <= 0:
    # Add dummy clickable region so indexes stay consistent
    this.clickables.add (start: minRenderX, stop: minRenderX, characters: @[])
    return

  let
    textColor =
      if this.wanted.monitorSelected: toColor(this.settings.selectionColor)
      else: toColor(this.settings.fgColor)
    desc = this.fonts.allFonts
  # One layout is measured and drawn.
  case this.settings.windowTitlePosition
  of wtpLeft:
    let
      layout = this.newLayout(title, desc, available)
      info = measure(layout, title)
    this.drawLayout(layout, info.height, minRenderX, textColor)
    g_object_unref(layout)
    this.clickables.add (
      start: minRenderX, stop: minRenderX + info.width, characters: info.characters
    )
  of wtpCenter:
    let layout = this.newLayout(title, desc)
    var info = measure(layout, title)
    var pos = max(minRenderX, this.wanted.width div 2 - info.width div 2)
    if pos + info.width > maxRenderX:
      # Does not fit centered: shift left, then clip.
      pos = max(minRenderX, maxRenderX - info.width)
    if info.width > maxRenderX - pos:
      pango_layout_set_width(layout, ((maxRenderX - pos) * PANGO_SCALE).cint)
      pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
      info = measure(layout, title)
    this.drawLayout(layout, info.height, pos, textColor)
    g_object_unref(layout)
    this.clickables.add (start: pos, stop: pos + info.width, characters: info.characters)

proc draw(this: StatusBar, data: pointer) =
  ## Draws the whole bar into the pixel buffer.
  let
    width = this.wanted.width
    height = this.wanted.height
    # The buffer is in physical pixels, drawing is in logical units.
    pixelWidth = this.pool.width
    pixelHeight = this.pool.height
    surface = cairo_image_surface_create_for_data(
      data, CAIRO_FORMAT_ARGB32, pixelWidth.cint, pixelHeight.cint,
      (pixelWidth * 4).cint
    )
  cairo_surface_set_device_scale(
    surface, pixelWidth.float / width.float, pixelHeight.float / height.float
  )
  this.cr = cairo_create(surface)
  reset this.clickables
  this.checkMetrics()

  # Background, including its transparency.
  let bg = toColor(this.settings.bgColor, this.settings.transparency)
  this.fillRect(bg, 0, 0, width, height, true)

  let tagLengthPixels = this.renderTags()
  # The title needs to know where the status starts, but the click regions are
  # ordered tags, title, status.
  let tagRegions = this.clickables.len
  let trayLeft = this.renderTray()
  let statusLeft = this.renderStatus(trayLeft, tagLengthPixels)
  let statusRegions = this.clickables[tagRegions .. ^1]
  this.clickables.setLen tagRegions
  this.renderActiveWindowTitle(tagLengthPixels, statusLeft - boxWidth * 2)
  this.clickables.add statusRegions

  cairo_destroy(this.cr)
  this.cr = nil
  cairo_surface_flush(surface)
  cairo_surface_destroy(surface)

proc regionAt*(this: StatusBar, x, y: int): ClickedRegion =
  ## Finds the clickable region at the position (surface coordinates), as of the last draw.
  for i, segment in this.clickables:
    if segment.start <= x and segment.stop > x:
      for c, character in segment.characters:
        if x < segment.start + character:
          return ClickedRegion(
            regionID: i,
            width: segment.stop - segment.start,
            index: c - 1,
            regionCord: (x: segment.start, y: 0),
            clickCord: (x: x, y: y)
          )
      return ClickedRegion(
        regionID: i,
        width: segment.stop - segment.start,
        index: segment.characters.high,
        regionCord: (x: segment.start, y: 0),
        clickCord: (x: x, y: y)
      )
  return ClickedRegion(
    regionID: -1,
    width: -1,
    index: -1,
    regionCord: (x: -1, y: -1),
    clickCord: (x: -1, y: -1)
  )

# ---------------------------------------------------------------------------
# Committing
# ---------------------------------------------------------------------------

proc flush*(this: StatusBar, x, y, width: int, visible: bool) =
  ## Positions the bar's node and, if anything changed, redraws and commits it.
  ## Only valid during a manage or render sequence.
  river_node_v1_set_position(this.node, x.int32, y.int32)
  this.originX = x
  this.originY = y

  this.wanted.width = width
  this.wanted.height = this.settings.height.int
  this.wanted.scale120 = this.scale120
  this.wanted.visible = visible and width > 0 and this.settings.height > 0
  this.wanted.configGen = this.configGen

  if not this.wanted.visible:
    this.trayRegions.setLen 0
    if this.drawn.visible:
      # Unmap the bar.
      river_shell_surface_v1_sync_next_commit(this.shell)
      wl_surface_attach(this.scaled.surface, nil, 0, 0)
      wl_surface_commit(this.scaled.surface)
    this.drawn = this.wanted
    return

  if this.wanted == this.drawn:
    return

  let
    pixelWidth = this.scaled.physical(width)
    pixelHeight = this.scaled.physical(this.wanted.height)
  if not this.pool.resize(pixelWidth, pixelHeight):
    # Retried (not before a short backoff) by the next flush.
    return
  let index = this.pool.acquire()
  if index == -1:
    # Both buffers are still held by the compositor; the pool asks for a new
    # manage sequence once one is released.
    return
  this.draw(this.pool.data(index))
  this.scaled.prepare(width, this.wanted.height)
  river_shell_surface_v1_sync_next_commit(this.shell)
  this.pool.present(index, this.scaled.surface)
  this.drawn = this.wanted
