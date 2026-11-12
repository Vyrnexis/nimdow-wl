import
  math,
  client,
  area,
  ../sys/logger

type MasterStackLayout* = ref object
  monitorArea*: Area
  gapSize*: uint
  borderWidth*: uint
  masterSlots*: uint
  widthDiff*: int
  defaultWidth*: int
  outerGap*: uint
  ## The screen width `widthDiff` was last derived from (see `setDefaultWidth`).
  widthBasis*: int

func calcScreenWidth*(this: MasterStackLayout, offset: LayoutOffset): int =
  this.monitorArea.width.int - offset.left.int - offset.right.int

func calcScreenHeight*(this: MasterStackLayout, offset: LayoutOffset): int =
  this.monitorArea.height.int - offset.top.int - offset.bottom.int

func edgeGap(this: MasterStackLayout): uint =
  ## The gap between the clients and the screen edge: the outer gap, which
  ## falls back to the gap between clients while it is 0.
  if this.outerGap > 0: this.outerGap else: this.gapSize

proc setDefaultWidth*(this: MasterStackLayout, offset: LayoutOffset) =
  let screenWidth = calcScreenWidth(this, offset)
  this.widthBasis = screenWidth
  let pxPercent = math.round(screenWidth.float / 100).int
  this.widthDiff = (this.defaultWidth - 50) * pxPercent

proc newMasterStackLayout*(
  monitorArea: Area,
  gapSize: uint,
  defaultWidth: int,
  borderWidth: uint,
  masterSlots: uint,
  layoutOffset: LayoutOffset,
  outerGap: uint = 0
): MasterStackLayout =
  ## Creates a new MasterStack layout.
  ## masterSlots: The number of clients allowed on the left half of the screen (traditionally 1).
  result = MasterStackLayout(
    monitorArea: monitorArea,
    gapSize: gapSize,
    defaultWidth: defaultWidth,
    borderWidth: borderWidth,
    masterSlots: masterSlots,
    outerGap: outerGap
  )
  result.setDefaultWidth(layoutOffset)

proc calcClientWidth*(this: MasterStackLayout, screenWidth: uint): uint =
  ## client width per pane excluding borders & gaps
  uint max(
    0,
    math.round(screenWidth.float / 2).int -
      (this.borderWidth * 2).int -
        this.edgeGap.int -
          math.round(this.gapSize.float * 0.5).int
  )

proc calculateClientHeight(this: MasterStackLayout, clientsInColumn: uint, screenHeight: uint): uint =
  ## Calculates the height of a client, including borders.
  if clientsInColumn <= 0:
    return 0

  let availableHeight =
    screenHeight.int -
      int((clientsInColumn - 1) * this.gapSize) -
        int(clientsInColumn * (this.borderWidth * 2)) -
          int(this.edgeGap * 2)

  if availableHeight <= 0:
    return 0

  result = math.round(availableHeight.float / clientsInColumn.float).uint

proc calcRoundingErr(this: MasterStackLayout, clientsInColumn, clientHeight, screenHeight: uint): int =
  ## Calculates the overall rounding error created from diving an imperfect number of pixels.
  ## E.g. A screen with a height of 1080px cannot be evenly divided by 7 clients.
  return
    screenHeight.int -
      int(clientsInColumn * (clientHeight + this.borderWidth * 2)) -
        int(int(this.gapSize) * int(clientsInColumn) - int(this.gapSize)) -
          int(this.edgeGap * 2)

proc calcYPosition(
  this: MasterStackLayout,
  stackIndex,
  clientsInColumn,
  clientHeight: uint,
  roundingError: int
): uint =
  ## Calculates the y position of a client within a client stack.
  var pos = int(this.edgeGap) + int(stackIndex * (this.gapSize + clientHeight + this.borderWidth * 2))
  if stackIndex == clientsInColumn - 1:
     pos += roundingError

  return max(0, pos).uint

proc layoutSingleClient(
  this: MasterStackLayout,
  client: Client,
  screenWidth: uint,
  screenHeight: uint,
  offset: LayoutOffset
) =
  # Hide border if it's the only client
  if this.outerGap == 0:
    client.borderWidth = 0

  client.resize(
    this.monitorArea.x + offset.left.int + int(this.outerGap),
    this.monitorArea.y + offset.top.int + int(this.outerGap),
    # Computed signed: narrow screens must not underflow.
    max(1, screenWidth.int - this.outerGap.int * 2 - client.borderWidth.int * 2).uint,
    max(1, screenHeight.int - this.outerGap.int * 2 - client.borderWidth.int * 2).uint
  )

proc layoutMultipleClients(
  this: MasterStackLayout,
  clients: seq[Client],
  screenWidth: uint,
  screenHeight: uint,
  offset: LayoutOffset
) =
  let clientCount = clients.len.uint
  let masterClientCount = min(clientCount, this.masterSlots)
  # Ensure stack size isn't negative
  let stackClientCount = max(0, clientCount.int - this.masterSlots.int).uint

  # If there are only master clients, take up all horizontal space.
  let normalClientWidth =
    if masterClientCount == clientCount or masterClientCount == 0:
      this.calcClientWidth(screenWidth) * 2
    else:
      this.calcClientWidth(screenWidth)

  let masterClientHeight = this.calculateClientHeight(masterClientCount, screenHeight)
  let stackClientHeight = this.calculateClientHeight(stackClientCount, screenHeight)

  let stackRoundingErr: int = this.calcRoundingErr(stackClientCount, stackClientHeight, screenHeight)
  let masterRoundingErr: int = this.calcRoundingErr(masterClientCount, masterClientHeight, screenHeight)

  let outerGap = this.edgeGap

  let stackXPos: uint =
    if masterClientCount == 0:
      outerGap
    else:
      uint math.round(screenWidth.float / 2).int + math.round(this.gapSize.float / 2).int + this.widthDiff

  let widthDiff =
    if masterClientCount == clientCount or masterClientCount == 0:
      0
    else:
      this.widthDiff

  for (i, client) in clients.pairs():
    var xPos, yPos, clientWidth, clientHeight: uint
    if i.uint < masterClientCount:
      # Master layout
      xPos = outerGap
      yPos = this.calcYPosition(i.uint, masterClientCount, masterClientHeight, masterRoundingErr)
      clientHeight = masterClientHeight
      clientWidth = uint(normalClientWidth.int + widthDiff)
    else:
      # Stack layout
      xPos = stackXPos
      let stackIndex = i.uint - masterClientCount
      yPos = this.calcYPosition(stackIndex, stackClientCount, stackClientHeight, stackRoundingErr)
      clientHeight = stackClientHeight
      clientWidth = uint(normalClientWidth.int - widthDiff)

    client.borderWidth = this.borderWidth
    client.resize(
      this.monitorArea.x + (xPos + offset.left).int,
      this.monitorArea.y + (yPos + offset.top).int,
      clientWidth,
      clientHeight
    )

proc arrange*(
  this: MasterStackLayout,
  clients: seq[Client],
  offset: LayoutOffset
) =
  ## Aligns the clients in a master/stack fashion. `clients` are the ones to
  ## tile, in stack order (no floating, fullscreen or fixed size clients).
  if clients.len == 0:
    return
  let screenWidth = calcScreenWidth(this, offset)
  let screenHeight = calcScreenHeight(this, offset)

  if screenWidth <= 0 or screenHeight <= 0:
    log "Screen width and height must be > 0!", lvlError
    return

  if clients.len == 1:
    this.layoutSingleClient(clients[0], screenWidth.uint, screenHeight.uint, offset)
  else:
    this.layoutMultipleClients(clients, screenWidth.uint, screenHeight.uint, offset)
