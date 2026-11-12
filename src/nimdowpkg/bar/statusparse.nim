import
  std/[unicode, strutils, tables, os, math],
  types,
  ../config/configloader,
  ../wl/cairo,
  ../wl/cursor,
  ../wl/protocols/[river_window_management_v1, viewporter, fractional_scale_v1]

proc sanitize*(s: string): string =
  ## Replaces invalid UTF-8 and line breaks, which pango does not like.
  if validateUtf8(s) == -1 and s.find({'\n', '\r', '\t'}) < 0:
    return s
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

proc parseStatus*(this: StatusBar, str: string): ParsedStatus =
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
