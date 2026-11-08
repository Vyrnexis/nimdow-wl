import
  nimtest,
  unicode

# parseStatus is private: include the module to test it.
include bar/statusparse

proc parse(s: string): ParsedStatus =
  StatusBar().parseStatus(s)

describe "status parsing":

  it "groups characters of the same color into runs":
    let p = parse("ab\e[31mcd\e[0mef")
    assert p.runs.len == 3
    assert p.runs[0].text == "ab" and p.runs[0].fg == -1
    assert p.runs[1].text == "cd" and p.runs[1].fg == basicColors[1]
    assert p.runs[2].text == "ef" and p.runs[2].fg == -1
    assert p.runs[1].first == 2 and p.runs[1].count == 2
    assert p.runs[2].first == 4

  it "counts unit separators as characters of their own":
    let p = parse("ab\x1Fcd")
    assert p.runs.len == 3
    assert p.runs[1].isSeparator
    assert p.runs[1].first == 2
    assert p.runs[2].first == 3 and p.runs[2].text == "cd"

  it "counts multibyte characters once":
    let p = parse("é€\x1F\u{E0BA}x")
    assert p.runs[0].text == "é€" and p.runs[0].count == 2
    assert p.runs[1].first == 2
    assert p.runs[2].first == 3 and p.runs[2].count == 2
    assert p.runs[2].text.runeLen == 2

  it "reads 24 bit, 256 color and background colors":
    let p = parse("\e[38;2;104;157;106ma\e[48;5;196mb\e[49mc")
    assert p.runs[0].fg == 0x689d6a and p.runs[0].bg == -1
    assert p.runs[1].bg == extraColors[196]
    assert p.runs[2].bg == -1 and p.runs[2].fg == 0x689d6a

  it "ignores invalid sequences":
    let p = parse("\e[3x1mab\e[31;;mc")
    assert p.runs[0].fg == -1

  it "finds Powerline glyphs without a background":
    let p = parse("\u{E0BA}\e[42mx")
    assert p.probe == "\u{E0BA}"
