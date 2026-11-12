import
  std/options,
  strutils,
  tables,
  listutils,
  sugar

import
  clientlist,
  area,
  ../config/configloader,
  ../bar/statusbar,
  ../wl/protocols/river_window_management_v1,
  ../sys/logger

export options

type
  Monitor* = ref object of RootObj
    id*: MonitorID
    ## The River output this monitor was built from.
    output*: RiverOutputV1
    area*: Area
    monitorSettings*: MonitorSettings
    windowSettings: WindowSettings
    previousTagID*: TagID
    layoutOffset*: LayoutOffset
    ## Height reserved at the top of the monitor for the status bar
    ## (0 while the bar is disabled or unavailable).
    barHeight*: uint
    ## Space taken by layer shell surfaces (e.g. another bar) at each edge,
    ## from river_layer_shell_output_v1.non_exclusive_area.
    reserved*: LayoutOffset
    ## Nil when the bar is unavailable (no wl_compositor/wl_shm).
    statusBar*: StatusBar
    isStatusBarEnabled*: bool
    taggedClients*: TaggedClients
    ## State the layout depends on changed outside of the mutators that relayout
    ## themselves; `doLayout` is due before the next manage sequence is applied.
    layoutDirty*: bool
    ## The stacking order last sent to River (bottom to top).
    sentStack*: seq[RiverNodeV1]

proc doLayout*(this: Monitor)
proc updateMonitor*(this: Monitor)
proc setSelectedClient*(this: Monitor, client: Client)

proc newMonitor*(
  id: MonitorID,
  output: RiverOutputV1,
  area: Area,
  currentConfig: Config
): Monitor =
  result = Monitor()
  result.id = id
  result.output = output
  result.area = area
  if currentConfig.monitorSettings.hasKey(id):
    result.monitorSettings = currentConfig.monitorSettings[id]
  else:
    result.monitorSettings = currentConfig.defaultMonitorSettings
  result.windowSettings = currentConfig.windowSettings
  result.taggedClients = newTaggedClients()
  result.isStatusBarEnabled = true
  for i in 1..tagCount:
    let tagSetting = result.monitorSettings.tagSettings[i]
    let tag: Tag = newTag(
      id = i,
      layout = newMasterStackLayout(
        monitorArea = area,
        gapSize = result.monitorSettings.layoutSettings.gapSize,
        defaultWidth = tagSetting.defaultMasterWidthPercentage,
        borderWidth = currentConfig.windowSettings.borderWidth,
        masterSlots = tagSetting.numMasterWindows.uint,
        layoutOffset = result.layoutOffset,
        outerGap = result.monitorSettings.layoutSettings.outerGap
      )
    )
    result.taggedClients.tags.add(tag)

  # Select the 2nd tag as the previous tag.
  result.previousTagID = result.taggedClients.tags[1].id

  result.taggedClients.selectedTags = initOrderedSet[TagID](tagCount)
  result.taggedClients.selectedTags.incl(1)
  result.updateMonitor()

proc reservedBarHeight(this: Monitor): uint =
  if this.statusBar != nil and this.isStatusBarEnabled:
    this.monitorSettings.barSettings.height
  else:
    0

proc calcLayoutOffset(this: Monitor): LayoutOffset =
  ## Layer shell reservations plus nimdow's own bar, which sits below any
  ## layer surface reserving the top edge.
  (
    this.reserved.top + this.barHeight,
    this.reserved.left,
    this.reserved.bottom,
    this.reserved.right
  )

proc usableArea*(this: Monitor): Area =
  ## The monitor's area without the space taken by layer shell surfaces and
  ## nimdow's own bar. Floating windows are placed and clamped inside it.
  let
    o = this.layoutOffset
    width = max(this.area.width.int - o.left.int - o.right.int, 1)
    height = max(this.area.height.int - o.top.int - o.bottom.int, 1)
  (this.area.x + o.left.int, this.area.y + o.top.int, width.uint, height.uint)

proc updateMonitor*(this: Monitor) =
  ## Recomputes the layout offset (bar space) and relayouts, e.g. after the
  ## output geometry changed.
  this.barHeight = this.reservedBarHeight()
  this.layoutOffset = this.calcLayoutOffset()
  for tag in this.taggedClients.tags:
    tag.layout.monitorArea = this.area
    # The width the user set (widthDiff) survives bar toggles and changes of
    # the reservation that leave the screen width as it was.
    if tag.layout.calcScreenWidth(this.layoutOffset) != tag.layout.widthBasis:
      tag.layout.setDefaultWidth(this.layoutOffset)
  this.doLayout()

########################################################
#### Helper procs, iterators, templates, and macros ####
########################################################

template tags*(this: Monitor): seq[Tag] =
  this.taggedClients.tags

template selectedTags*(this: Monitor): OrderedSet[TagID] =
  this.taggedClients.selectedTags

template clients*(this: Monitor): DoublyLinkedList[Client] =
  this.taggedClients.clients

template clientSelection*(this: Monitor): seq[Client] =
  this.taggedClients.clientSelection

proc windowSettings*(this: Monitor): WindowSettings = this.windowSettings

proc enableStatusBar*(this: Monitor) =
  this.isStatusBarEnabled = true
  this.updateMonitor()

proc disableStatusBar*(this: Monitor) =
  this.isStatusBarEnabled = false
  this.updateMonitor()

proc toggleStatusBar*(this: Monitor) =
  if this.statusBar == nil:
    log "Status bar is unavailable", lvlWarn
  elif this.isStatusBarEnabled:
    this.disableStatusBar()
  else:
    this.enableStatusBar()

proc syncStatusBar*(this: Monitor, isSelected: bool) =
  ## Hands the bar what it should show. The bar redraws only when this differs
  ## from what it last drew (see `StatusBar.flush`).
  if this.statusBar == nil:
    return
  let currClient = this.taggedClients.currClient
  var perTag: array[TagID, BarTag]
  for state in perTag.mitems:
    state.empty = true
  for client in this.clients.items:
    for tagID in client.tagIDs:
      perTag[tagID].empty = false
      perTag[tagID].urgent = perTag[tagID].urgent or client.isUrgent
      if client == currClient:
        perTag[tagID].hasCurrent = true
  var
    tagStates: array[TagID.high, BarTag]
    count = 0
  for tagID in this.monitorSettings.tagSettings.keys():
    tagStates[count] = perTag[tagID]
    tagStates[count].selected = tagID in this.selectedTags
    inc count
  const noTitle = ""
  let title {.cursor.} = if currClient != nil: currClient.title else: noTitle
  this.statusBar.update(tagStates.toOpenArray(0, count - 1), title, isSelected)

proc setConfig*(this: Monitor, config: Config) =
  this.windowSettings = config.windowSettings
  if config.monitorSettings.hasKey(this.id):
    this.monitorSettings = config.monitorSettings[this.id]
  else:
    this.monitorSettings = config.defaultMonitorSettings

  this.barHeight = this.reservedBarHeight()
  this.layoutOffset = this.calcLayoutOffset()
  if this.statusBar != nil:
    this.statusBar.setConfig(
      this.monitorSettings.barSettings, this.monitorSettings.tagSettings
    )

  for i, tag in this.tags:
    let tagSetting = this.monitorSettings.tagSettings[i + 1]
    tag.layout.gapSize = this.monitorSettings.layoutSettings.gapSize
    tag.layout.borderWidth = this.windowSettings.borderWidth
    tag.layout.masterSlots = tagSetting.numMasterWindows.uint
    tag.layout.outerGap = this.monitorSettings.layoutSettings.outerGap
    tag.layout.defaultWidth = tagSetting.defaultMasterWidthPercentage
    tag.layout.setDefaultWidth(this.layoutOffset)

  for client in this.taggedClients.clients:
    if client.borderWidth != 0 or this.monitorSettings.layoutSettings.outerGap > 0:
      client.borderWidth = this.windowSettings.borderWidth

  this.doLayout()

proc setSelectedClient*(this: Monitor, client: Client) =
  ## Marks the client as the most recently selected. The selected client of the
  ## selected tags is what gets keyboard focus on the next manage sequence.
  if client != nil:
    if client.isUrgent:
      client.setUrgent(false)
    if client.monitorID != this.id:
      log "Attempted to select a client not on the current tags"
      return

    # The topmost fullscreen client depends on the selection order.
    for other in this.clients.items:
      if other.isFullscreen:
        this.layoutDirty = true
        break

    this.taggedClients.selectClient(client.window)

proc tagIDFromArg*(this: Monitor, arg: string): Option[TagID] =
  ## Parses a tag number from an action argument (the key name or IPC argument).
  try:
    let tagNumber = parseInt(arg)
    if tagNumber < 1 or tagNumber > this.tags.len:
      log "Invalid tag number: " & $tagNumber, lvlError
      return
    return this.tags[tagNumber - 1].id.option
  except ValueError:
    log "Invalid tag number \"" & arg & "\": " & getCurrentExceptionMsg(), lvlError

proc doLayout*(this: Monitor) =
  ## Revalidates the current layout of the viewed tag(s).
  ## Only computes areas and visibility; nothing is sent to River until the
  ## next manage/render sequence.
  let tag = this.taggedClients.findFirstSelectedTag()
  if tag != nil:
    tag.layout.arrange(
      this.taggedClients.findCurrentClients(),
      this.layoutOffset
    )
  this.layoutDirty = false

  # Only the topmost (most recently selected) fullscreen client is shown while
  # there is one on the viewed tags, and it gets the focus.
  var topmostFullscreen: Client
  for client in this.taggedClients.currClientsSelectionNewToOldIter:
    if client.isFullscreen:
      topmostFullscreen = client
      break
  if topmostFullscreen != nil and
     this.taggedClients.currClient != topmostFullscreen:
    this.taggedClients.selectClient(topmostFullscreen.window)

  for client in this.clients.mitems:
    client.isVisible =
      this.taggedClients.isOnSelectedTags(client) and
      (topmostFullscreen == nil or client == topmostFullscreen)

proc removeWindow*(this: Monitor, window: Window): bool =
  ## Returns if the window was removed.
  ## After a window is removed, you should typically call doLayout.
  result = this.taggedClients.removeByWindow(window)
  if result:
    this.sentStack.setLen 0

proc toggleTagsForClient*(
  this: Monitor,
  client: Client,
  tagIDs: varargs[TagID]
) =
  # Cache if the client was on the current tags.
  let wasOnCurrTags = this.taggedClients.isOnSelectedTags(client)

  var firstTagToggledOff: int = 0
  for id in tagIDs:
    if client.tagIDs.contains(id):
      if firstTagToggledOff == 0:
        firstTagToggledOff = id
      client.tagIDs.excl(id)
    else:
      client.tagIDs.incl(id)

  # Ensure the client is assigned at least one tag.
  if client.tagIDs.len == 0 and firstTagToggledOff != 0:
    client.tagIDs.incl(firstTagToggledOff.TagID)

  # Perform the layout if the client was added to or removed from the current tags.
  if wasOnCurrTags != this.taggedClients.isOnSelectedTags(client):
    this.doLayout()

proc addClient*(this: Monitor, client: Client, assignToSelectedTags: bool = true) =
  this.sentStack.setLen 0
  client.monitorID = this.id
  this.clients.append(client)
  this.clientSelection.add(client)
  if assignToSelectedTags:
    client.tagIDs = {}
    for id in this.selectedTags:
      client.tagIDs.incl(id)
    # Nothing viewed: fall back to the previous tag, else the first.
    if client.tagIDs.len == 0:
      client.tagIDs.incl(
        if this.previousTagID != 0: this.previousTagID
        else: this.taggedClients.tags[0].id
      )
  this.doLayout()

proc rotateClients*(this: Monitor) =
  let clientNode = this.taggedClients.findLastLayoutNode()
  if clientNode != nil:
    this.clients.remove(clientNode)
    this.clients.prepend(clientNode)
    this.doLayout()

proc moveClientToTag*(this: Monitor, client: Client, destinationTagID: TagID) =
  if client.tagIDs == {destinationTagID}:
    return

  # Change client tags to only destinationTag id.
  client.tagIDs = {destinationTagID}

  this.doLayout()

  if destinationTagID in this.selectedTags:
    this.setSelectedClient(client)

proc moveSelectedWindowToTag*(this: Monitor, tagID: TagID) =
  this.taggedClients.withSomeCurrClient(client):
    this.moveClientToTag(client, tagID)

proc toggleTags*(this: Monitor, tagIDs: varargs[TagID]) =
  ## Toggles the given tags in the view. Never leaves the view empty (as dwm).

  var tags = this.selectedTags
  for id in tagIDs:
    if tags.contains(id):
      tags.excl(id)
    else:
      tags.incl(id)

  if tags.len == 0:
    return
  this.selectedTags = tags
  this.doLayout()

proc setSelectedTags*(this: Monitor, tagIDs: varargs[TagID]) =
  ## Views the given tags.

  # Select only the given tags
  this.selectedTags.clear()
  for id in tagIDs:
    this.selectedTags.incl(id)
  this.doLayout()

proc focusNextClient*(this: Monitor, reversed: bool) =
  ## Focuses the next client in the stack.
  let currClient = this.taggedClients.currClient
  if currClient != nil and currClient.isFullscreen:
    # Fullscreen clients should be the ONLY thing you interact with.
    return

  let node = this.taggedClients.findNextCurrClient(currClient, reversed)
  if node != nil:
    this.setSelectedClient(node.value)

proc focusNextClient*(this: Monitor) =
  ## Focuses the next client in the stack.
  this.focusNextClient(false)

proc focusPreviousClient*(this: Monitor) =
  ## Focuses the previous client in the stack.
  this.focusNextClient(true)

proc moveClientNext*(
  this: Monitor,
  reversed: bool
) =
  ## Moves the client to the next position in the stack.
  var currNode = this.taggedClients.currClientNode
  if currNode == nil:
    return

  var node = this.taggedClients.findNextCurrClient(
    currNode.value,
    reversed,
    (client: Client) => not client.isFloating and not client.isFixedSize
  )

  if node != nil and node.value != nil:
    swap(currNode, node)
    this.setSelectedClient(node.value)
    this.doLayout()

proc moveClientNext*(this: Monitor) =
  ## Moves the client to the next position in the stack.
  this.moveClientNext(false)

proc moveClientPrevious*(this: Monitor) =
  ## Moves the client to the previous position in the stack.
  this.moveClientNext(true)

proc setFullscreen*(this: Monitor, client: Client, fullscreen: bool) =
  ## Fullscreen is realised by `river_window_v1.fullscreen` in the next manage
  ## sequence; here only the state changes. The client's own area is kept so it
  ## is restored when leaving fullscreen.
  if client.isFullscreen == fullscreen:
    return
  client.isFullscreen = fullscreen
  this.doLayout()

proc toggleFullscreenForSelectedClient*(this: Monitor) =
  this.taggedClients.withSomeCurrClient(client):
    this.setFullscreen(client, not client.isFullscreen)

proc setFloating*(this: Monitor, client: Client, floating: bool, fit = false) =
  ## Changes the client's floating state and relayouts. A floating client keeps
  ## the area it had (the last tiled area when it was tiled before), unless
  ## `fit`: it then gets its last floating area, or is centered at the
  ## floatingWidth x floatingHeight percentages of the usable area.
  if floating == client.isFloating:
    return

  client.isFloating = floating

  if not floating:
    if client.width > 0 and client.height > 0:
      client.floatArea = (
        client.x - this.area.x, client.y - this.area.y, client.width, client.height
      )
  else:
    if client.borderWidth == 0:
      client.borderWidth = this.windowSettings.borderWidth
    let usable = this.usableArea()
    if fit:
      let settings = this.windowSettings
      if client.floatArea.width > 0:
        let last = client.floatArea
        client.area = clampFloating(
          (this.area.x + last.x, this.area.y + last.y, last.width, last.height),
          usable, client.borderWidth
        )
      else:
        client.area = percentArea(
          usable, settings.floatingWidth, settings.floatingHeight, client.borderWidth
        )
      client.needsCenter = false
    let
      maxWidth = usable.width.int - client.borderWidth.int * 2
      maxHeight = usable.height.int - client.borderWidth.int * 2
    if client.width.int > maxWidth and maxWidth > 0:
      client.width = maxWidth.uint
    if client.height.int > maxHeight and maxHeight > 0:
      client.height = maxHeight.uint

  this.doLayout()

proc toggleFloatingForSelectedClient*(this: Monitor) =
  this.taggedClients.withSomeCurrClient(client):
    if client.isFixedSize or client.isFullscreen:
      return
    this.setFloating(client, not client.isFloating, fit = true)

proc adjustFloating*(this: Monitor, dx, dy, dw, dh: int) =
  ## Moves/resizes the selected client by the deltas if it is floating.
  this.taggedClients.withSomeCurrClient(client):
    if client.isFloating and not client.isFullscreen and client.width > 0:
      client.area = clampFloating(
        (
          client.x + dx, client.y + dy,
          max(client.width.int + dw, 0).uint, max(client.height.int + dh, 0).uint
        ),
        this.usableArea(), client.borderWidth
      )

proc centerFloating*(this: Monitor) =
  ## Centers the selected client in the usable area if it is floating.
  this.taggedClients.withSomeCurrClient(client):
    if client.isFloating and not client.isFullscreen and client.width > 0:
      client.area = centeredArea(
        this.usableArea(), client.width, client.height, client.borderWidth
      )

proc findNext*(monitors: openArray[Monitor], current: Monitor): int =
  ## Finds the next monitor index from index `i` (exclusive), iterating forward.
  ## This search will loop the array.
  for i in countup(monitors.low, monitors.high):
    if monitors[i] == current:
      if i == monitors.high:
        return monitors.low
      return i + 1
  return -1

proc findPrevious*(monitors: openArray[Monitor], current: Monitor): int =
  ## Finds the next monitor index from index `i` (exclusive), iterating backward.
  ## This search will loop the array.
  for i in countdown(monitors.high, monitors.low):
    if monitors[i] == current:
      if i == monitors.low:
        return monitors.high
      return i - 1
  return -1

proc find*(monitors: OrderedTable[MonitorID, Monitor], x, y: int): tuple[index: int, monitor: Monitor] =
  ## Finds a monitor's index based on the given location.
  ## -1 is returned if no monitors contain the location.

  for i, monitor in monitors:
    if monitor.area.contains(x, y):
      return (i, monitor)

  var shortestDist = float.high
  # Find the closest monitor based on distance to its center.
  for i, monitor in monitors:
    let dist = min(shortestDist, monitor.area.distanceToCenterSquared(x, y))
    if dist < shortestDist:
      shortestDist = dist
      result = (i, monitor)
