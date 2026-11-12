import
  nimtest,
  os,
  tray/icons

proc pixmap(size: int, valid = true): IconPixmap =
  IconPixmap(width: size, height: size, data: newString(if valid: size * size * 4 else: 1))

describe "Tray pixmap choice":

  it "finds nothing without pixmaps":
    assert choosePixmap(@[], 22) == -1

  it "prefers the smallest pixmap that is large enough":
    assert choosePixmap(@[pixmap(16), pixmap(64), pixmap(32)], 22) == 2

  it "takes the largest when all are too small":
    assert choosePixmap(@[pixmap(16), pixmap(48), pixmap(32)], 64) == 1

  it "skips truncated and empty pixmaps":
    assert choosePixmap(@[pixmap(32, valid = false), pixmap(16)], 22) == 1
    assert choosePixmap(@[IconPixmap()], 22) == -1

  it "skips oversized pixmaps":
    assert choosePixmap(@[pixmap(MaxPixmapSize + 1), pixmap(16)], 22) == 1

describe "PNG size limit":

  proc header(w, h: uint32): string =
    proc be(v: uint32): string =
      for s in [24, 16, 8, 0]:
        result.add char((v shr s) and 0xff)
    "\x89PNG\r\n\x1a\n" & be(13) & "IHDR" & be(w) & be(h)

  it "reads the size from the IHDR":
    let dir = getTempDir()
    let path = dir / "nimdow-icons-test.png"
    defer: removeFile(path)
    writeFile(path, header(64, 64))
    assert not pngTooLarge(path)
    writeFile(path, header(1024, 1024))
    assert not pngTooLarge(path)
    writeFile(path, header(1025, 16))
    assert pngTooLarge(path)
    writeFile(path, header(16, 100000))
    assert pngTooLarge(path)
    writeFile(path, "not a png at all, just text")
    assert pngTooLarge(path)
