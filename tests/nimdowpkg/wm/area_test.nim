import
  nimtest,
  wm/area

const usable: Area = (0, 20, 1000.uint, 580.uint)

describe "Floating geometry":

  it "centers the percentage area, border included":
    let a = percentArea(usable, 50, 50, 2)
    assert (a.width, a.height) == (496.uint, 286.uint)
    assert (a.x, a.y) == (250, 20 + 145)

  it "centers an area of the same size":
    let a = centeredArea(usable, 100, 60, 1)
    assert (a.x, a.y) == (449, 20 + 259)

  it "keeps a valid area as it is":
    let a: Area = (100, 100, 300.uint, 200.uint)
    assert clampFloating(a, usable, 1) == a

  it "limits the size to the minimum and the usable area":
    let small = clampFloating((100, 100, 10.uint, 10.uint), usable, 1)
    assert (small.width, small.height) == (MinFloatSize.uint, MinFloatSize.uint)
    let big = clampFloating((0, 20, 5000.uint, 5000.uint), usable, 1)
    assert (big.width, big.height) == (998.uint, 578.uint)

  it "keeps part of the window on screen":
    let left = clampFloating((-5000, 100, 300.uint, 200.uint), usable, 1)
    assert left.x + 302 == MinFloatSize
    let right = clampFloating((5000, 100, 300.uint, 200.uint), usable, 1)
    assert right.x == 1000 - MinFloatSize
    let up = clampFloating((100, -5000, 300.uint, 200.uint), usable, 1)
    assert up.y + 202 == 20 + MinFloatSize
    let down = clampFloating((100, 5000, 300.uint, 200.uint), usable, 1)
    assert down.y == 600 - MinFloatSize

  it "applies a step by adding it and clamping":
    let a: Area = (100, 100, 300.uint, 200.uint)
    let wider = clampFloating((a.x, a.y, (a.width.int + 40).uint, a.height), usable, 1)
    assert wider.width == 340
    let narrower = clampFloating((a.x, a.y, max(a.width.int - 400, 0).uint, a.height), usable, 1)
    assert narrower.width == MinFloatSize.uint
