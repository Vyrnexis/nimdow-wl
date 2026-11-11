## The hotkey overlay: every key binding of the loaded config, listed in
## sections. `overlayContent` builds the text from the config; `HotkeyOverlay`
## shows it as a `river_shell_surface_v1`, drawn with cairo + pango like the bar
## (same fonts and colors, fractional scale through wp_viewporter) and closed
## by a click. The surface only exists while the overlay is open and is only
## redrawn when the content, the output size or the scale changed.
##
## `flush` must only be called during a render sequence.

import
  std/[tables, strutils, unicode],
  fonts,
  render,
  statusbar,
  types,
  ../config/configloader,
  ../wl/cairo,
  ../wl/shm,
  ../wl/protocols/river_window_management_v1,
  ../wm/commands

# ---------------------------------------------------------------------------
# Content
# ---------------------------------------------------------------------------

type
  Section* = enum
    secWindows = "Windows", secFloating = "Floating", secTags = "Tags",
    secLayout = "Layout", secMonitors = "Monitors", secScratchpad = "Scratchpad",
    secLaunch = "Launch", secMedia = "Media & hardware", secSession = "Session"

  OverlayRow* = object
    label*, keys*: string

  OverlaySection* = object
    title*: string
    rows*: seq[OverlayRow]

proc info*(command: WMCommand): tuple[section: Section, label: string] =
  ## Where a control is listed and how it reads. Exhaustive: a new control
  ## does not compile until it has an entry here.
  case command
  of wmcFocusNext: (secWindows, "Focus next window")
  of wmcFocusPrevious: (secWindows, "Focus previous window")
  of wmcMoveWindowNext: (secWindows, "Move window down the stack")
  of wmcMoveWindowPrevious: (secWindows, "Move window up the stack")
  of wmcToggleFullscreen: (secWindows, "Toggle fullscreen")
  of wmcDestroySelectedWindow: (secWindows, "Close window")
  of wmcJumpToUrgentWindow: (secWindows, "Jump to urgent window")
  of wmcToggleFloating: (secFloating, "Toggle floating")
  of wmcCenterFloating: (secFloating, "Center floating window")
  of wmcMoveFloatingLeft: (secFloating, "Move floating window left")
  of wmcMoveFloatingDown: (secFloating, "Move floating window down")
  of wmcMoveFloatingUp: (secFloating, "Move floating window up")
  of wmcMoveFloatingRight: (secFloating, "Move floating window right")
  of wmcResizeFloatingNarrower: (secFloating, "Make floating window narrower")
  of wmcResizeFloatingWider: (secFloating, "Make floating window wider")
  of wmcResizeFloatingShorter: (secFloating, "Make floating window shorter")
  of wmcResizeFloatingTaller: (secFloating, "Make floating window taller")
  of wmcGoToTag: (secTags, "Go to tag")
  of wmcGoToLeftTag: (secTags, "Go to the tag on the left")
  of wmcGoToRightTag: (secTags, "Go to the tag on the right")
  of wmcGoToPreviousTag: (secTags, "Go to the previous tag")
  of wmcMoveWindowToTag: (secTags, "Move window to tag")
  of wmcMoveWindowToLeftTag: (secTags, "Move window to the tag on the left")
  of wmcMoveWindowToRightTag: (secTags, "Move window to the tag on the right")
  of wmcMoveWindowToPreviousTag: (secTags, "Move window to the previous tag")
  of wmcToggleTagView: (secTags, "Show or hide tag")
  of wmcToggleWindowTag: (secTags, "Add or remove window on tag")
  of wmcIncreaseMasterCount: (secLayout, "More master windows")
  of wmcDecreaseMasterCount: (secLayout, "Fewer master windows")
  of wmcIncreaseMasterWidth: (secLayout, "Widen master area")
  of wmcDecreaseMasterWidth: (secLayout, "Narrow master area")
  of wmcRotateclients: (secLayout, "Rotate windows")
  of wmcToggleStatusBar: (secLayout, "Toggle status bar")
  of wmcFocusPreviousMonitor: (secMonitors, "Focus previous monitor")
  of wmcFocusNextMonitor: (secMonitors, "Focus next monitor")
  of wmcMoveWindowToPreviousMonitor: (secMonitors, "Move window to previous monitor")
  of wmcMoveWindowToNextMonitor: (secMonitors, "Move window to next monitor")
  of wmcMoveWindowToScratchpad: (secScratchpad, "Move window to scratchpad")
  of wmcPopScratchpad: (secScratchpad, "Show scratchpad window")
  of wmcToggleHotkeyOverlay: (secSession, "Show key bindings")
  of wmcLockSession: (secSession, "Lock screen")
  of wmcReloadConfig: (secSession, "Reload config")
  of wmcExitSession: (secSession, "Exit")
  of wmcStatus: (secSession, "Set status text")
  of wmcDumpState: (secSession, "Dump state")

const
  modifierNames = [
    (RIVER_SEAT_V1_MODIFIERS_MOD4, "Super"), (RIVER_SEAT_V1_MODIFIERS_CTRL, "Ctrl"),
    (RIVER_SEAT_V1_MODIFIERS_MOD1, "Alt"), (RIVER_SEAT_V1_MODIFIERS_SHIFT, "Shift"),
    (RIVER_SEAT_V1_MODIFIERS_MOD3, "Mod3"), (RIVER_SEAT_V1_MODIFIERS_MOD5, "Mod5")
  ]
  keyNames = {
    "return": "Enter", "kp_enter": "Enter", "space": "Space", "escape": "Esc",
    "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "minus": "-",
    "equal": "=", "semicolon": ";", "apostrophe": "'", "grave": "`",
    "bracketleft": "[", "bracketright": "]",
    "xf86audioraisevolume": "Volume up", "xf86audiolowervolume": "Volume down",
    "xf86audiomute": "Mute", "xf86audiomicmute": "Mic mute",
    "xf86monbrightnessup": "Brightness up", "xf86monbrightnessdown": "Brightness down",
    "xf86kbdbrightnessup": "Keyboard light up", "xf86kbdbrightnessdown": "Keyboard light down",
    "xf86audioplay": "Play/pause", "xf86audionext": "Next track",
    "xf86audioprev": "Previous track", "xf86audiostop": "Stop"
  }.toTable

proc keyName*(key: string): string =
  ## A key as it reads on screen: "Return" is "Enter", "j" is "J".
  let known = keyNames.getOrDefault(key.toLowerAscii)
  if known.len > 0: known
  elif key.len == 1: key.toUpperAscii
  elif key.toLowerAscii.startsWith("xf86"): key[4 .. ^1]
  else: key

proc keysText*(modifiers: uint32, keys: seq[string]): string =
  ## "Super + Shift + J". Keys that are a run of digits are shown as a range
  ## ("Super + 1–9"), other keys are listed ("Super + Left / Right").
  for (mask, name) in modifierNames:
    if (modifiers and mask) != 0:
      result.add name & " + "
  var run = keys.len >= 3
  for i, key in keys:
    if key.len != 1 or key[0] notin {'0' .. '9'} or (i > 0 and key[0] != keys[i - 1][0].succ):
      run = false
  if run:
    return result & keys[0] & "–" & keys[^1]
  for i, key in keys:
    if i > 0:
      result.add " / "
    result.add keyName(key)

proc shorten(command: string, maxLen = 30): string =
  let text = command.strip()
  if text.runeLen <= maxLen: text else: text.runeSubStr(0, maxLen - 1) & "…"

proc overlayContent*(config: Config): seq[OverlaySection] =
  ## The bound keys by section, in config order. Controls and click regions
  ## without keys do not appear; empty sections are left out.
  type Entry = object
    binding: Binding
    modifiers: uint32
    keys: seq[string]
  var entries: seq[Entry]
  for combo, binding in config.bindings.pairs:
    var found = false
    for entry in entries.mitems:
      if entry.binding == binding and entry.modifiers == combo.modifiers:
        entry.keys.add combo.key
        found = true
        break
    if not found:
      entries.add Entry(binding: binding, modifiers: combo.modifiers, keys: @[combo.key])
  var rows: array[Section, seq[OverlayRow]]
  for entry in entries:
    var section: Section
    var label: string
    if entry.binding.isProcess:
      section = secLaunch
      for key in entry.keys:
        if key.toLowerAscii.startsWith("xf86") or key.toLowerAscii == "print":
          section = secMedia
      label = if entry.binding.description.len > 0: entry.binding.description
        else: shorten(entry.binding.name)
    else:
      let command = parseCommand(entry.binding.name)
      if command.isNone:
        continue
      (section, label) = info(command.get)
    rows[section].add OverlayRow(label: label, keys: keysText(entry.modifiers, entry.keys))
  for section in Section:
    if rows[section].len > 0:
      result.add OverlaySection(title: $section, rows: rows[section])

# ---------------------------------------------------------------------------
# Layout and drawing
# ---------------------------------------------------------------------------

const
  border = 2
  pad = 20
  columnGap = 40
  keyGap = 24
  rowPad = 4
  sectionGap = 12
  ## The part of the output the overlay may use.
  screenPercent = 90

type
  ## What the layout and the buffer are made from.
  DrawKey = object
    areaWidth, areaHeight, scale120, gen: int

  Column = object
    first, last: int
    labelWidth, keysWidth: int

  HotkeyOverlay* = ref object
    ctx: BarContext
    ## The config the content was built from.
    config*: Config
    settings: BarSettings
    fonts: FontSet
    sections: seq[OverlaySection]
    ## Incremented when the content changed.
    gen: int
    scaled: ScaledSurface
    pool: ShmPool
    shell: RiverShellSurfaceV1
    node: RiverNodeV1
    target: InputTarget
    ## The overlay was clicked (handled by the window manager).
    clicked*: bool
    columns: seq[Column]
    ## The size of the content, and of the overlay: the content is scaled down
    ## when it does not fit the output.
    contentWidth, contentHeight, width, height, rowHeight: int
    laid, drawn: DrawKey
    hasLaid, hasDrawn: bool

proc newHotkeyOverlay*(ctx: BarContext): HotkeyOverlay =
  HotkeyOverlay(ctx: ctx)

proc isOpen*(this: HotkeyOverlay): bool = this.shell != nil

proc setContent*(this: HotkeyOverlay, config: Config, settings: BarSettings) =
  this.config = config
  this.settings = settings
  this.fonts = this.ctx.fontSetFor(settings.fonts)
  this.sections = overlayContent(config)
  inc this.gen

proc open*(this: HotkeyOverlay, scale120: int) =
  if this.isOpen:
    return
  let
    ctx = this.ctx
    overlay = this
  this.scaled = newScaledSurface(
    ctx.compositor, ctx.viewporter, ctx.fractionalManager, scale120,
    proc() =
      overlay.target.scale120 = overlay.scaled.scale120
      if ctx.requestManage != nil:
        ctx.requestManage()
  )
  this.pool = newShmPool(ctx.shm, "nimdow-overlay", proc() =
    if ctx.requestManage != nil:
      ctx.requestManage()
  )
  this.shell = river_window_manager_v1_get_shell_surface(ctx.manager, this.scaled.surface)
  this.node = river_shell_surface_v1_get_node(this.shell)
  this.target = InputTarget(
    surface: this.scaled.surface, scale120: this.scaled.scale120,
    button: proc(button, x, y: int) =
      overlay.clicked = true
      if ctx.requestManage != nil:
        ctx.requestManage()
  )
  ctx.targets.add this.target
  this.hasLaid = false
  this.hasDrawn = false
  this.clicked = false

proc close*(this: HotkeyOverlay) =
  if not this.isOpen:
    return
  this.ctx.removeTarget(this.target)
  this.pool.destroy()
  river_node_v1_destroy(this.node)
  river_shell_surface_v1_destroy(this.shell)
  this.scaled.destroy()
  this.shell = nil
  this.target = nil

proc newLayout(cr: Cairo, text: string, desc: PangoFontDescription): PangoLayout =
  result = pango_cairo_create_layout(cr)
  pango_layout_set_font_description(result, desc)
  pango_layout_set_text(result, text.cstring, text.len.cint)

proc textSize(cr: Cairo, text: string, desc: PangoFontDescription): tuple[w, h: int] =
  let layout = newLayout(cr, text, desc)
  var w, h: cint
  pango_layout_get_pixel_size(layout, addr w, addr h)
  g_object_unref(layout)
  (w.int, h.int)

proc sectionHeight(this: HotkeyOverlay, section: int): int =
  (1 + this.sections[section].rows.len) * this.rowHeight + sectionGap

proc pack(this: HotkeyOverlay, limit: int): seq[Column] =
  ## Fills columns with whole sections, a new column when the next does not fit.
  var y = 0
  for i in 0 ..< this.sections.len:
    let h = this.sectionHeight(i)
    if result.len == 0 or y + h > limit:
      result.add Column(first: i, last: i)
      y = 0
    result[^1].last = i
    y += h

proc computeLayout(this: HotkeyOverlay, areaWidth, areaHeight: int) =
  ## Columns, as few as fit the output, and the size of the overlay (logical pixels).
  let
    desc = this.fonts.allFonts
    surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1)
    deviceScale = this.scaled.scale120.float / 120.0
  # Measured like drawn: with the device scale, so the font metrics match.
  cairo_surface_set_device_scale(surface, deviceScale, deviceScale)
  let cr = cairo_create(surface)
  this.rowHeight = textSize(cr, "Ag", desc).h + rowPad
  var
    labelWidths, keysWidths: seq[int]
    tallest, total = 0
  for i, section in this.sections:
    var label = textSize(cr, section.title, desc).w
    var keys = 0
    for row in section.rows:
      label = max(label, textSize(cr, row.label, desc).w)
      keys = max(keys, textSize(cr, row.keys, desc).w)
    labelWidths.add label
    keysWidths.add keys
    tallest = max(tallest, this.sectionHeight(i))
    total += this.sectionHeight(i)
  cairo_destroy(cr)
  cairo_surface_destroy(surface)

  let availHeight = areaHeight * screenPercent div 100 - 2 * (pad + border)
  var limit = availHeight
  if this.sections.len > 0:
    # Balance the columns: the least height that keeps their number.
    let count = this.pack(availHeight).len
    limit = max(tallest, total div count)
    while limit < availHeight and this.pack(limit).len > count:
      limit += this.rowHeight
    limit = min(limit, availHeight)
  this.columns = this.pack(limit)
  var columnsHeight = 0
  this.contentWidth = 2 * (pad + border) - columnGap
  for column in this.columns.mitems:
    var height = 0
    for i in column.first .. column.last:
      column.labelWidth = max(column.labelWidth, labelWidths[i])
      column.keysWidth = max(column.keysWidth, keysWidths[i])
      height += this.sectionHeight(i)
    columnsHeight = max(columnsHeight, height - sectionGap)
    this.contentWidth += columnGap + column.labelWidth + keyGap + column.keysWidth
  this.contentHeight = columnsHeight + 2 * (pad + border)
  let shrink = min(1.0, min(
    areaWidth.float * screenPercent / 100 / this.contentWidth.float,
    areaHeight.float * screenPercent / 100 / this.contentHeight.float
  ))
  this.width = int(this.contentWidth.float * shrink)
  this.height = int(this.contentHeight.float * shrink)

proc draw(this: HotkeyOverlay, data: pointer) =
  let
    settings = this.settings
    desc = this.fonts.allFonts
    surface = cairo_image_surface_create_for_data(
      data, CAIRO_FORMAT_ARGB32, this.pool.width.cint, this.pool.height.cint,
      (this.pool.width * 4).cint
    )
  cairo_surface_set_device_scale(
    surface, this.pool.width.float / this.contentWidth.float,
    this.pool.height.float / this.contentHeight.float
  )
  let
    cr = cairo_create(surface)
    background = toColor(settings.bgColor, settings.transparency)
    frame = toColor(settings.menuBorderColor)
    normal = toColor(settings.fgColor)
    heading = toColor(settings.selectionColor)
    keys = toColor(settings.hasWindowsColor)
  proc fill(color: Color, x, y, w, h: int) =
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a)
    cairo_rectangle(cr, x.cdouble, y.cdouble, w.cdouble, h.cdouble)
    cairo_fill(cr)
  proc show(color: Color, text: string, x, y: int) =
    let layout = newLayout(cr, text, desc)
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a)
    cairo_move_to(cr, x.cdouble, (y + rowPad div 2).cdouble)
    pango_cairo_show_layout(cr, layout)
    g_object_unref(layout)
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
  fill(frame, 0, 0, this.contentWidth, this.contentHeight)
  fill(background, border, border, this.contentWidth - 2 * border,
    this.contentHeight - 2 * border)
  cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
  var x = pad + border
  for column in this.columns:
    var y = pad + border
    for i in column.first .. column.last:
      let section = this.sections[i]
      show(heading, section.title, x, y)
      y += this.rowHeight
      for row in section.rows:
        show(normal, row.label, x, y)
        show(keys, row.keys, x + column.labelWidth + keyGap, y)
        y += this.rowHeight
      y += sectionGap
    x += column.labelWidth + keyGap + column.keysWidth + columnGap
  cairo_destroy(cr)
  cairo_surface_flush(surface)
  cairo_surface_destroy(surface)

proc flush*(this: HotkeyOverlay, x, y, width, height: int) =
  ## Centers the overlay in the output area, puts it on top of everything and
  ## redraws it if needed. Render sequence only.
  if not this.isOpen:
    return
  let key = DrawKey(
    areaWidth: width, areaHeight: height, scale120: this.scaled.scale120, gen: this.gen
  )
  if not this.hasLaid or this.laid != key:
    this.computeLayout(width, height)
    this.laid = key
    this.hasLaid = true
  river_node_v1_set_position(
    this.node, (x + (width - this.width) div 2).int32, (y + (height - this.height) div 2).int32
  )
  river_node_v1_place_top(this.node)
  if this.hasDrawn and this.drawn == key:
    return
  if this.width <= 0 or this.height <= 0 or
      not this.pool.resize(this.scaled.physical(this.width), this.scaled.physical(this.height)):
    return
  let index = this.pool.acquire()
  if index == -1:
    # Retried once a buffer is released (the pool requests a manage sequence).
    return
  this.draw(this.pool.data(index))
  this.scaled.prepare(this.width, this.height)
  river_shell_surface_v1_sync_next_commit(this.shell)
  this.pool.present(index, this.scaled.surface)
  this.drawn = key
  this.hasDrawn = true
