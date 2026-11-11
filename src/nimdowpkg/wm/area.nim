import math

type Point*[T] = tuple[x, y: T]

type
  Area* = tuple[x, y: int, width, height: uint]
  ## Space taken at each edge of a monitor (layer surfaces, the status bar).
  LayoutOffset* = tuple[top, left, bottom, right: uint]

proc center*(this: Area): Point[float] =
  ## Calculates the center of the area.
  return (
    this.x.float + (this.width.int) / 2,
    this.y.float + (this.height.int) / 2
  )

proc contains*(this: Area, x, y: int): bool =
  return
    x >= this.x and
    y >= this.y and
    x < this.x + this.width.int and
    y < this.y + this.height.int

proc distanceToCenterSquared*(this: Area, x, y: int): float =
  let center = this.center()
  return pow(abs(center.x - x.float), 2f) + pow(abs(center.y - y.float), 2f)

proc `$`*(this: Area): string =
  "[x: " & $this.x & ", y: " & $this.y & ", width: " & $this.width & ", height: " & $this.height & "]"


const MinFloatSize* = 50
  ## Smallest size of a floating window, and the part of it that stays on screen.

proc centeredArea*(usable: Area, width, height, border: uint): Area =
  ## `width` and `height` exclude the border.
  (
    usable.x + (usable.width.int - width.int - border.int * 2) div 2,
    usable.y + (usable.height.int - height.int - border.int * 2) div 2,
    width,
    height
  )

proc percentArea*(usable: Area, widthPercent, heightPercent: int, border: uint): Area =
  ## The area centered in `usable` that, with its border, takes the given percentages.
  centeredArea(
    usable,
    max(usable.width.int * widthPercent div 100 - border.int * 2, 1).uint,
    max(usable.height.int * heightPercent div 100 - border.int * 2, 1).uint,
    border
  )

proc clampFloating*(area: Area, usable: Area, border: uint): Area =
  ## Limits the size to [`MinFloatSize`, usable area] and keeps at least
  ## `MinFloatSize` pixels of the window inside the usable area.
  let
    b = border.int * 2
    maxWidth = max(usable.width.int - b, 1)
    maxHeight = max(usable.height.int - b, 1)
    width = clamp(area.width.int, min(MinFloatSize, maxWidth), maxWidth)
    height = clamp(area.height.int, min(MinFloatSize, maxHeight), maxHeight)
    keepX = min(MinFloatSize, width + b)
    keepY = min(MinFloatSize, height + b)
  (
    clamp(area.x, usable.x - width - b + keepX, usable.x + usable.width.int - keepX),
    clamp(area.y, usable.y - height - b + keepY, usable.y + usable.height.int - keepY),
    width.uint,
    height.uint
  )
