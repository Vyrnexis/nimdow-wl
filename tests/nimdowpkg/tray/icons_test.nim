import
  nimtest,
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
