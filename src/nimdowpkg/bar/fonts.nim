import
  std/[unicode, strutils, math],
  types,
  ../wl/cairo,
  ../wl/cursor,
  ../wl/protocols/[river_window_management_v1, viewporter, fractional_scale_v1]

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

proc primary*(fonts: FontSet): PangoFontDescription =
  ## The default font, for text that selects none.
  fonts.fonts[0]

proc buildFontSet(names: seq[string]): FontSet =
  ## One description per configured font, for explicit font selection. Only
  ## the first is used by default: listing an emoji font (e.g. Noto Color
  ## Emoji, the default config's second font) as a fallback makes Pango draw
  ## ASCII digits with its keycap glyphs. Fontconfig's own fallback still finds
  ## emoji/icon glyphs.
  result = FontSet(names: names)
  for font in names:
    result.fonts.add pango_font_description_from_string(toPangoString(font).cstring)
  if result.fonts.len == 0:
    result.fonts.add pango_font_description_from_string("monospace 10")

proc newLayout*(cr: Cairo, text: string, desc: PangoFontDescription): PangoLayout =
  ## A new layout of the text; release it with g_object_unref.
  result = pango_cairo_create_layout(cr)
  pango_layout_set_font_description(result, desc)
  pango_layout_set_text(result, text.cstring, text.len.cint)

proc textSize*(cr: Cairo, text: string, desc: PangoFontDescription): tuple[w, h: int] =
  ## The size of the text in pixels.
  let layout = newLayout(cr, text, desc)
  var w, h: cint
  pango_layout_get_pixel_size(layout, addr w, addr h)
  g_object_unref(layout)
  (w.int, h.int)

proc fontSetFor*(ctx: BarContext, names: seq[string]): FontSet =
  ## The font set of a configuration, built once and shared by all bars (and
  ## the menu popups) using the same fonts.
  if ctx.fontCache == nil or ctx.fontCache.names != names:
    ctx.fontCache = buildFontSet(names)
  ctx.fontCache
