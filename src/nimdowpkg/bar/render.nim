import
  std/[unicode, strutils, tables, math, sequtils],
  types,
  fonts,
  input,
  statusparse,
  ../sys/logger,
  ../config/configloader,
  ../wl/cairo,
  ../wl/cursor,
  ../wl/shm,
  ../tray/tray,
  ../wl/protocols/[river_window_management_v1, viewporter, fractional_scale_v1]

const
  boxWidth = 4
  rightPadding = 4

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

type Color* = tuple[r, g, b, a: float]

proc toColor*(hex: int, alpha: uint8 = 255): Color =
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

proc draw*(this: StatusBar, data: pointer) =
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
