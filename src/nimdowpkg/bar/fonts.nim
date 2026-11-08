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

proc fontSetFor*(ctx: BarContext, names: seq[string]): FontSet =
  ## The font set of a configuration, built once and shared by all bars (and
  ## the menu popups) using the same fonts.
  if ctx.fontCache == nil or ctx.fontCache.names != names:
    ctx.fontCache = buildFontSet(names)
  ctx.fontCache
