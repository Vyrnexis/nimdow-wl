import
  std/[options, tables, sets, math],
  parsetoml,
  types,
  outputs,
  debug,
  inputconfig,
  clientlist,
  overlay,
  monitor,
  area,
  ../tray/tray,
  ../config/configloader,
  masterstack,
  commands,
  ../wl/protocols/[river_window_management_v1, river_xkb_bindings_v1, river_layer_shell_v1],
  ../sys/logger,
  ../sys/spawn

proc mapConfigActions*(this: WindowManager)

proc findRelativeTag*(this: WindowManager, offset: int): Tag =
  let selectedTag = this.selectedMonitor.taggedClients.findFirstSelectedTag
  if selectedTag.isNil:
    return

  var tagNumber = (selectedTag.id + offset) mod this.selectedMonitor.tags.len
  if tagNumber <= 0:
    tagNumber = this.selectedMonitor.tags.len
  return this.selectedMonitor.tags[tagNumber - 1]

proc increaseMasterCount(this: WindowManager) =
  let firstSelectedTag = this.selectedMonitor.taggedClients.findFirstSelectedTag()
  if firstSelectedTag == nil:
    return

  firstSelectedTag.layout.masterSlots.inc
  this.selectedMonitor.doLayout()

proc decreaseMasterCount(this: WindowManager) =
  let firstSelectedTag = this.selectedMonitor.taggedClients.findFirstSelectedTag()
  if firstSelectedTag == nil:
    return

  let layout = firstSelectedTag.layout
  if layout.masterSlots > 0:
    layout.masterSlots.dec
    this.selectedMonitor.doLayout()

proc goToTag*(this: WindowManager, tagID: TagID) =
  # Check if only the same tag is shown
  let selectedTags = this.selectedMonitor.selectedTags

  var destTag = tagID
  if selectedTags.len == 1:
    # Find the only selected tag
    var selectedTag: TagID
    for tag in selectedTags:
      selectedTag = tag
      break

    # If attempting to select the same single tag, view the previous tag instead.
    if this.selectedMonitor.previousTagID != 0 and selectedTag == destTag:
      destTag = this.selectedMonitor.previousTagID

    # Swap the previous tag.
    this.selectedMonitor.previousTagID = selectedTag

  this.selectedMonitor.setSelectedTags(destTag)

proc modWidthDiff(this: WindowManager, diff: int) =
  let firstTag = this.selectedMonitor.taggedClients.findFirstSelectedTag
  if firstTag == nil:
    return
  let
    layout = firstTag.layout
    screenWidth = layout.calcScreenWidth(this.selectedMonitor.layoutOffset)

  if
    (diff > 0 and layout.widthDiff < 0) or
    (diff < 0 and layout.widthDiff > 0) or
    layout.calcClientWidth(screenWidth.uint).int - abs(layout.widthDiff) - abs(diff) > 0:
      layout.widthDiff += diff
      this.selectedMonitor.doLayout()

proc increaseMasterWidth(this: WindowManager) =
  this.modWidthDiff(this.selectedMonitor.monitorSettings.layoutSettings.resizeStep.int)

proc decreaseMasterWidth(this: WindowManager) =
  this.modWidthDiff(-this.selectedMonitor.monitorSettings.layoutSettings.resizeStep.int)

proc destroySelectedWindow*(this: WindowManager) =
  ## Asks the selected window to close (sent during the next manage sequence).
  this.selectedMonitor.taggedClients.withSomeCurrClient(client):
    client.closeRequested = true

proc focusMonitor(this: WindowManager, monitor: Monitor) =
  ## Selects the monitor; the pointer follows to its current client.
  if monitor == nil:
    return
  this.selectedMonitor = monitor
  this.warpMonitor = monitor
  this.warpClient = monitor.taggedClients.currClient

proc focusMonitorIndex(this: WindowManager, index: int) =
  ## `index` is zero-based, in position order.
  if index in 0 .. this.sortedMonitors().high:
    this.focusMonitor(this.sortedMonitors()[index])

proc focusNextMonitor(this: WindowManager) =
  this.focusMonitorIndex(this.sortedMonitors().findNext(this.selectedMonitor))

proc focusPreviousMonitor(this: WindowManager) =
  this.focusMonitorIndex(this.sortedMonitors().findPrevious(this.selectedMonitor))

proc moveClientToMonitor*(
  this: WindowManager,
  client: Client,
  destination: Monitor,
  keepPosition: bool = false
) =
  ## Moves the client to the selected tags of `destination`, which becomes the
  ## selected monitor. A floating client keeps its offset in the monitor
  ## (or its absolute position if `keepPosition`).
  let start = this.monitorOf(client)
  if start == nil or destination == nil or start == destination:
    return

  if start.removeWindow(client.window):
    start.doLayout()

  if client.isFloating and not keepPosition:
    client.x = destination.area.x + (client.x - start.area.x)
    client.y = destination.area.y + (client.y - start.area.y)

  this.selectedMonitor = destination
  destination.addClient(client)
  if not keepPosition:
    # (A client dropped after a drag is already under the pointer.)
    this.warpMonitor = destination
    this.warpClient = client

proc moveSelectedClientToMonitor(this: WindowManager, destination: Monitor) =
  let client = this.selectedMonitor.taggedClients.currClient
  if client != nil:
    this.moveClientToMonitor(client, destination)

proc moveWindowToNextMonitor(this: WindowManager) =
  let i = this.sortedMonitors().findNext(this.selectedMonitor)
  if i >= 0:
    this.moveSelectedClientToMonitor(this.sortedMonitors()[i])

proc moveWindowToPreviousMonitor(this: WindowManager) =
  let i = this.sortedMonitors().findPrevious(this.selectedMonitor)
  if i >= 0:
    this.moveSelectedClientToMonitor(this.sortedMonitors()[i])

proc moveWindowToScratchpad(this: WindowManager) =
  let client = this.selectedMonitor.taggedClients.currClient
  if client == nil:
    return
  client.tagIDs = {}
  discard this.selectedMonitor.removeWindow(client.window)
  this.selectedMonitor.doLayout()
  client.isVisible = false
  this.scratchpad.add client

proc popScratchpad(this: WindowManager) =
  if this.scratchpad.len == 0:
    return
  let client = this.scratchpad.pop()
  let monitor = this.selectedMonitor
  let settings = this.config.scratchpadSettings

  # Placed in the middle of the usable area (below the bar and layer surfaces).
  let usable = monitor.usableArea()
  if not client.isFullscreen and not client.isFloating and not client.isFixedSize:
    client.borderWidth = this.config.windowSettings.borderWidth
    let
      width = clamp(settings.width, 1, max(usable.width.int - client.borderWidth.int * 2, 1))
      height = clamp(settings.height, 1, max(usable.height.int - client.borderWidth.int * 2, 1))
    client.area = centeredArea(usable, width.uint, height.uint, client.borderWidth)
    client.isFloating = true
  else:
    let centered = centeredArea(
      usable,
      (if client.width > 0: client.width.int else: max(client.reportedWidth, 0)).uint,
      (if client.height > 0: client.height.int else: max(client.reportedHeight, 0)).uint,
      client.borderWidth
    )
    client.x = centered.x
    client.y = centered.y
  client.needsCenter = false
  monitor.addClient(client)
  this.warpMonitor = monitor
  this.warpClient = client

proc applyConfig*(this: WindowManager, config: Config, configTable: TomlTable) =
  ## Fills `config` from the config table and makes it the active config.
  ## The one place that runs the config population steps, in their required
  ## order (the actions must exist before key combos are bound to them).
  ## Raises if the config is invalid; the previous config stays active then.
  let previous = this.config
  this.config = config
  try:
    # Actions must exist before the key combos are bound to them.
    this.mapConfigActions()
    config.load(configTable)
    logger.enabled = config.loggingEnabled
  except Exception:
    this.config = previous
    raise

proc reloadConfig*(this: WindowManager) =
  let oldLoggingEnabled = logger.enabled

  try:
    # strict: a broken file keeps the running config instead of the defaults.
    this.applyConfig(newConfig(), configloader.loadConfigFile(strict = true))
  except Exception:
    # The old config stays active if the new one fails to load.
    logger.enabled = oldLoggingEnabled
    log getCurrentExceptionMsg(), lvlError
    return

  for monitor in this.monitors.mvalues():
    monitor.setConfig(this.config)

  applyInput(this.config.input)

  # trayEnabled may have changed: start or stop the tray.
  if this.tray != nil and this.tray.alive:
    this.tray.setTheme(this.config.trayIconTheme)
  if this.config.trayEnabled:
    if this.tray != nil and not this.tray.alive:
      this.tray = nil
    this.startTray()
  elif this.tray != nil:
    this.tray.stop()
    this.tray = nil

  # Bindings are re-created from the new key combos in the next manage sequence.
  this.bindingsDirty = true

template createControl(keyCombo: untyped, id: string, action: untyped) =
  this.config.configureAction(id, proc(keyCombo: KeyCombo) = action)

proc mapConfigActions*(this: WindowManager) =
  ## Maps available user configuration options to window manager actions.
  ## The `key` of the key combo is the argument for tag actions (a tag number).
  createControl(keyCombo, $wmcReloadConfig):
    this.reloadConfig()

  createControl(keyCombo, $wmcIncreaseMasterCount):
    this.increaseMasterCount()

  createControl(keyCombo, $wmcDecreaseMasterCount):
    this.decreaseMasterCount()

  createControl(keyCombo, $wmcMoveWindowToPreviousMonitor):
    this.moveWindowToPreviousMonitor()

  createControl(keyCombo, $wmcMoveWindowToNextMonitor):
    this.moveWindowToNextMonitor()

  createControl(keyCombo, $wmcFocusPreviousMonitor):
    this.focusPreviousMonitor()

  createControl(keyCombo, $wmcFocusNextMonitor):
    this.focusNextMonitor()

  createControl(keyCombo, $wmcGoToTag):
    var tagIDOpt = this.selectedMonitor.tagIDFromArg(keyCombo.key)
    if tagIDOpt.isSome:
      this.goToTag(tagIDOpt.get)

  createControl(keyCombo, $wmcGoToLeftTag):
    let leftTag = this.findRelativeTag(-1)
    if leftTag != nil:
      this.goToTag(leftTag.id)

  createControl(keyCombo, $wmcGoToRightTag):
    let rightTag = this.findRelativeTag(1)
    if rightTag != nil:
      this.goToTag(rightTag.id)

  createControl(keyCombo, $wmcGoToPreviousTag):
    var previousTag = this.selectedMonitor.previousTagID
    if previousTag != 0:
      this.goToTag(previousTag)

  createControl(keyCombo, $wmcMoveWindowToPreviousTag):
    var previousTagID = this.selectedMonitor.previousTagID
    if previousTagID != 0:
      this.selectedMonitor.moveSelectedWindowToTag(previousTagID)

  createControl(keyCombo, $wmcToggleTagView):
    let tagIDOpt = this.selectedMonitor.tagIDFromArg(keyCombo.key)
    if tagIDOpt.isSome:
      this.selectedMonitor.toggleTags(tagIDOpt.get)

  createControl(keyCombo, $wmcToggleWindowTag):
    this.selectedMonitor.taggedClients.withSomeCurrClient(client):
      let tagIDOpt = this.selectedMonitor.tagIDFromArg(keyCombo.key)
      if tagIDOpt.isSome:
        this.selectedMonitor.toggleTagsForClient(client, tagIDOpt.get)

  createControl(keyCombo, $wmcFocusNext):
    this.selectedMonitor.focusNextClient()

  createControl(keyCombo, $wmcFocusPrevious):
    this.selectedMonitor.focusPreviousClient()

  createControl(keyCombo, $wmcMoveWindowPrevious):
    this.selectedMonitor.moveClientPrevious()

  createControl(keyCombo, $wmcMoveWindowNext):
    this.selectedMonitor.moveClientNext()

  createControl(keyCombo, $wmcMoveWindowToTag):
    let tagIDOpt = this.selectedMonitor.tagIDFromArg(keyCombo.key)
    if tagIDOpt.isSome:
      this.selectedMonitor.moveSelectedWindowToTag(tagIDOpt.get)

  createControl(keyCombo, $wmcMoveWindowToLeftTag):
    let leftTag = this.findRelativeTag(-1)
    if leftTag != nil:
      this.selectedMonitor.moveSelectedWindowToTag(leftTag.id)

  createControl(keyCombo, $wmcMoveWindowToRightTag):
    let rightTag = this.findRelativeTag(1)
    if rightTag != nil:
      this.selectedMonitor.moveSelectedWindowToTag(rightTag.id)

  createControl(keyCombo, $wmcToggleFullscreen):
    this.selectedMonitor.toggleFullscreenForSelectedClient()

  createControl(keyCombo, $wmcDestroySelectedWindow):
    this.destroySelectedWindow()

  createControl(keyCombo, $wmcToggleFloating):
    this.selectedMonitor.toggleFloatingForSelectedClient()

  const floatingSteps = [
    ($wmcMoveFloatingLeft, -1, 0, 0, 0), ($wmcMoveFloatingDown, 0, 1, 0, 0),
    ($wmcMoveFloatingUp, 0, -1, 0, 0), ($wmcMoveFloatingRight, 1, 0, 0, 0),
    ($wmcResizeFloatingNarrower, 0, 0, -1, 0), ($wmcResizeFloatingTaller, 0, 0, 0, 1),
    ($wmcResizeFloatingShorter, 0, 0, 0, -1), ($wmcResizeFloatingWider, 0, 0, 1, 0)
  ]
  for i in 0 ..< floatingSteps.len:
    closureScope:
      let (id, dx, dy, dw, dh) = floatingSteps[i]
      createControl(keyCombo, id):
        let step = this.selectedMonitor.windowSettings.floatingStep
        this.selectedMonitor.adjustFloating(dx * step, dy * step, dw * step, dh * step)

  createControl(keyCombo, $wmcCenterFloating):
    this.selectedMonitor.centerFloating()

  createControl(keyCombo, $wmcIncreaseMasterWidth):
    this.increaseMasterWidth()

  createControl(keyCombo, $wmcDecreaseMasterWidth):
    this.decreaseMasterWidth()

  createControl(keyCombo, $wmcMoveWindowToScratchpad):
    this.moveWindowToScratchpad()

  createControl(keyCombo, $wmcPopScratchpad):
    this.popScratchpad()

  createControl(keyCombo, $wmcRotateclients):
    this.selectedMonitor.rotateClients()

  createControl(keyCombo, $wmcToggleStatusBar):
    this.selectedMonitor.toggleStatusBar()

  # The key is the output file (see `dumpState`).
  createControl(keyCombo, $wmcDumpState):
    this.dumpState(keyCombo.key)

  # Ends the whole River session (killing nimdow alone leaves River running).
  createControl(keyCombo, $wmcExitSession):
    river_window_manager_v1_exit_session(this.manager)

  createControl(keyCombo, $wmcLockSession):
    if not spawnShell(this.config.lockCommand):
      log "Failed to start the lock command: " & this.config.lockCommand, lvlWarn

  createControl(keyCombo, $wmcToggleHotkeyOverlay):
    this.toggleOverlay()

proc runAction(this: WindowManager, command: string, key: string) =
  ## Runs a configured action, never letting its failure take the manager down.
  try:
    this.config.actionIdentifierTable[command]((key, 0'u32))
  except CatchableError:
    log "Action " & command & " failed: " & getCurrentExceptionMsg(), lvlError

proc runIpcAction*(this: WindowManager, command: string, arg: string) =
  ## Runs the action for an IPC command (`arg` is e.g. a tag number).
  if not this.config.actionIdentifierTable.hasKey(command):
    return
  # Most actions work on the selected monitor, which is nil without outputs.
  if this.selectedMonitor == nil and
     command notin [$wmcReloadConfig, $wmcDumpState, $wmcExitSession]:
    log "No monitor to run " & command & " on", lvlWarn
    return
  this.runAction(command, arg)
  # The state changed outside of a manage sequence: have River start one.
  this.markDirty()
