import
  os,
  options,
  parsetoml,
  sets,
  strutils,
  tables

import
  apprules,
  tagsettings,
  ../wm/area,
  keys,
  ../sys/spawn,
  ../sys/logger,
  ../wm/commands

export options

const embeddedDefaultConfig = staticRead("../../../config.default.toml")
  ## Last-resort copy of config.default.toml, used when no config file can be read.

var configLoc*: string

proc userConfigPath*(): string =
  getConfigDir() / "nimdow-wl" / "config.toml"

proc findSystemConfig*(xdgConfigDirs = getEnv("XDG_CONFIG_DIRS")): string =
  ## First `nimdow-wl/config.toml` in $XDG_CONFIG_DIRS (default /etc/xdg), or "".
  let dirs = if xdgConfigDirs.len == 0: "/etc/xdg" else: xdgConfigDirs
  for dir in dirs.split(':'):
    if dir.len == 0:
      continue
    let path = dir / "nimdow-wl" / "config.toml"
    if fileExists(path):
      return path

proc seedUserConfig*(userPath, sourcePath: string, embeddedText = embeddedDefaultConfig): string =
  ## Copies `sourcePath` (or the embedded default when empty) to `userPath` if that
  ## does not exist yet; an existing file is never overwritten. Returns the path to
  ## load: `userPath` on success, else `sourcePath` ("" means the embedded default).
  if fileExists(userPath):
    return userPath
  try:
    createDir(parentDir(userPath))
    let text = if sourcePath.len > 0: readFile(sourcePath) else: embeddedText
    writeFile(userPath, text)
    log "created " & userPath & " from " &
      (if sourcePath.len > 0: sourcePath else: "the built-in default config"), lvlInfo
    return userPath
  except Exception:
    log "could not create " & userPath & ": " & getCurrentExceptionMsg(), lvlWarn
    return sourcePath

proc findConfigPath*(): string =
  ## User config, else the system one ($XDG_CONFIG_DIRS), else the embedded default
  ## (""). Without a user config, one is created from the chosen source.
  let user = userConfigPath()
  if fileExists(user):
    return user
  seedUserConfig(user, findSystemConfig())

type WindowTitlePosition* = enum
  wtpLeft, wtpCenter

type
  AccelProfile* = enum
    apAdaptive = "adaptive", apFlat = "flat"
  ClickMethod* = enum
    cmClickfinger = "clickfinger", cmButtonAreas = "buttonareas"
  ScrollMethod* = enum
    smTwoFinger = "twofinger", smEdge = "edge", smNone = "none"

  ## Every field is optional: unset means "leave the default".
  KeyboardSettings* = object
    layout*, variant*, options*, model*: Option[string]
    repeatRate*, repeatDelay*: Option[int]
    numlock*: Option[bool]
  ## The settings of touchpads and mice; the keys of the other kind stay unset.
  PointerSettings* = object
    tap*, naturalScroll*, disableWhileTyping*, leftHanded*: Option[bool]
    accelSpeed*: Option[float]
    accelProfile*: Option[AccelProfile]
    clickMethod*: Option[ClickMethod]
    scrollMethod*: Option[ScrollMethod]
  InputSettings* = object
    keyboard*: KeyboardSettings
    touchpad*, mouse*: PointerSettings

type
  KeyCombo* = tuple[key: string, modifiers: uint32]
    ## `key` is an xkbcommon key name ("Return", "i", "1", ...). For tag actions it
    ## doubles as the argument (the tag number); IPC passes the argument as `key`.
  Action* = proc(keyCombo: KeyCombo): void
  RegionClickAction* = proc(idx: int, width: int, regionCord: Point[int], clickCord: Point[int], button: int): void

  WindowSettings* = object
    borderColorUnfocused*: int
    borderColorFocused*: int
    borderColorUrgent*: int
    borderWidth*: uint
    modKey*: int
    ## Size (percent of the usable area) of a tiled window made floating.
    floatingWidth*, floatingHeight*: int
    ## Pixels per keyboard move/resize of a floating window.
    floatingStep*: int
  BarSettings* = object
    height*: uint
    windowTitlePosition*: WindowTitlePosition
    fonts*: seq[string]
    showIndicator*: bool
    # Hex values
    fgColor*, bgColor*, selectionColor*, urgentColor*, hasWindowsColor*: int
    transparency*: uint8
    ## Tray icon size is the bar height minus twice the padding.
    trayIconPadding*, trayIconSpacing*: uint
    ## Space on each side of a tag label in the bar.
    tagPadding*: uint
    ## Tray context menus: border color (hex) and minimum width.
    menuBorderColor*: int
    menuWidthMin*: uint
  ScratchpadSettings* = object
    width*: int
    height*: int
  LayoutSettings* = object
    gapSize*: uint
    outerGap*: uint
    resizeStep*: uint
  MonitorSettings* = object
    tagSettings*: TagSettings
    barSettings*: BarSettings
    layoutSettings*: LayoutSettings

  ## What a key combo runs, for the hotkey overlay: a control (`name` is its
  ## lowercase name) or a startProcess entry (`name` is its command).
  Binding* = object
    name*: string
    isProcess*: bool
    description*: string

  MonitorID* = int
  KeyIdentity = tuple[keysym: uint32, modifiers: uint32]
  Config* = ref object
    actionIdentifierTable*: Table[string, Action]
    keyComboTable*: Table[KeyCombo, Action]
    ## What each combo of `keyComboTable` is bound to, in config order.
    bindings*: OrderedTable[KeyCombo, Binding]
    ## The combos (of `keyComboTable`) that stay bound while the session is locked.
    whileLockedCombos*: HashSet[KeyCombo]
    keyIndex: Table[KeyIdentity, KeyCombo]
      ## One canonical KeyCombo per keysym + modifiers, so "r" and "R" share a binding.
    regionClickActionTable*: Table[int, RegionClickAction]
    windowSettings*: WindowSettings
    scratchpadSettings*: ScratchpadSettings
    loggingEnabled*: bool
    reverseTagScrolling*: bool
    trayEnabled*: bool
    ## 1-based index of the monitor (in screen order) whose bar shows the tray; 0 follows the selected monitor.
    trayMonitor*: int
    trayIconTheme*: string
    lockCommand*: string
    hotkeyOverlayAtStartup*: bool
    defaultMonitorSettings*: MonitorSettings
    # Specific monitor settings
    monitorSettings*: Table[MonitorID, MonitorSettings]
    appRules*: seq[AppRule]
    input*: InputSettings

proc defaultMonitorSettings(): MonitorSettings =
  result.barSettings = BarSettings(
    height: 20,
    windowTitlePosition: wtpCenter,
    fonts: @[
      "monospace:size=10:antialias=true",
      "NotoColorEmoji:size=10:antialias=true"
    ],
    showIndicator: true,
    fgColor: 0xfce8c3,
    bgColor: 0x1c1b19,
    selectionColor: 0x519f50,
    urgentColor: 0xef2f27,
    hasWindowsColor: 0xfce8c3,
    transparency: 255,
    trayIconPadding: 2,
    trayIconSpacing: 4,
    tagPadding: 8,
    menuBorderColor: 0x519f50,
    menuWidthMin: 150
  )
  result.layoutSettings = LayoutSettings(
    gapSize: 12,
    outerGap: 0,
    resizeStep: 10
  )
  result.tagSettings = createDefaultTagSettings()

proc newConfig*(): Config =
  Config(
    actionIdentifierTable: initTable[string, Action](),
    keyComboTable: initTable[KeyCombo, Action](),
    bindings: initOrderedTable[KeyCombo, Binding](),
    whileLockedCombos: initHashSet[KeyCombo](),
    windowSettings: WindowSettings(
      borderColorUnfocused: 0x1c1b19,
      borderColorFocused: 0x519f50,
      borderColorUrgent: 0xff5555,
      borderWidth: 1,
      modKey: ModifierTable["super"].int,
      floatingWidth: 50,
      floatingHeight: 50,
      floatingStep: 40
    ),
    scratchpadSettings: ScratchpadSettings(
      width: 500,
      height: 300,
    ),
    defaultMonitorSettings: defaultMonitorSettings(),

    loggingEnabled: false,
    trayEnabled: true,
    trayMonitor: 1,
    reverseTagScrolling: false,
    lockCommand: "swaylock -f -c 282828"
  )

# Typed accessors for config values: a missing key yields none, a value of the
# wrong type is logged and also yields none, so the caller keeps its default.

proc getInt(table: TomlTableRef, name: string, min = int.low): Option[int] =
  if not table.hasKey(name):
    return
  let value = table[name]
  if value.kind != TomlValueKind.Int:
    log name & " is not an integer value!", lvlWarn
  elif value.intVal < min:
    log name & " must be at least " & $min & "!", lvlWarn
  else:
    result = some(value.intVal.int)

proc getBool(table: TomlTableRef, name: string): Option[bool] =
  if not table.hasKey(name):
    return
  let value = table[name]
  if value.kind != TomlValueKind.Bool:
    log name & " is not true/false!", lvlWarn
  else:
    result = some(value.boolVal)

proc getStr(table: TomlTableRef, name: string): Option[string] =
  if not table.hasKey(name):
    return
  let value = table[name]
  if value.kind != TomlValueKind.String:
    log name & " is not a string!", lvlWarn
  else:
    result = some(value.stringVal)

proc getFloat(table: TomlTableRef, name: string, min, max: float): Option[float] =
  if not table.hasKey(name):
    return
  let value = table[name]
  var number: float
  case value.kind
  of TomlValueKind.Int: number = value.intVal.float
  of TomlValueKind.Float: number = value.floatVal
  else:
    log name & " is not a number!", lvlWarn
    return
  if number < min or number > max:
    log name & " must be between " & $min & " and " & $max & "!", lvlWarn
  else:
    result = some(number)

proc getEnum[T: enum](table: TomlTableRef, name: string): Option[T] =
  ## A string value naming one of the enum's values (case-insensitive).
  let text = table.getStr(name)
  if text.isNone:
    return
  for value in T:
    if $value == text.get.toLowerAscii:
      return some(value)
  log name & " has an invalid value: \"" & text.get & "\"", lvlWarn

proc parseHex*(text: string): Option[int] =
  ## Parses "rrggbb", "#rrggbb" or "0xrrggbb".
  try:
    result = some(fromHex[int](text.strip()))
  except ValueError:
    discard

proc getHex(table: TomlTableRef, name: string): Option[int] =
  let text = table.getStr(name)
  if text.isNone:
    if table.hasKey(name):
      log name & " is not a proper hex value! Ensure it is wrapped in double quotes", lvlWarn
    return
  result = parseHex(text.get)
  if result.isNone:
    log name & " is not a valid hex color: \"" & text.get & "\"", lvlWarn

template setIfSome(target: untyped, value: untyped) =
  let opt = value
  if opt.isSome:
    target = opt.get

template guarded(what: string, body: untyped) =
  ## Logs and swallows errors, so one bad config section cannot stop the rest from loading.
  try:
    body
  except Exception:
    log what & ": " & getCurrentExceptionMsg(), lvlError

proc configureAction*(this: Config, actionName: string, actionInvokee: Action) =
  this.actionIdentifierTable[actionName] = actionInvokee

proc registerCombo(
  this: Config, keyCombo: KeyCombo, action: Action, binding: Binding, whileLocked = false
) =
  ## Binds `action` to the combo; an equivalent combo spelled differently is replaced.
  let identity: KeyIdentity = (keyCombo.key.toKeysym(), keyCombo.modifiers)
  var combo = keyCombo
  if this.keyIndex.hasKey(identity):
    combo = this.keyIndex[identity]
    log "Key \"" & keyCombo.key & "\" duplicates \"" & combo.key & "\"; using the later binding", lvlWarn
  else:
    this.keyIndex[identity] = keyCombo
  this.keyComboTable[combo] = action
  this.bindings[combo] = binding
  if whileLocked:
    this.whileLockedCombos.incl combo
  else:
    this.whileLockedCombos.excl combo

proc getModifierMask(modifier: TomlValueRef): Option[uint32] =
  if modifier.kind != TomlValueKind.String:
    log "Invalid key configuration: " & repr(modifier) & " is not a string", lvlError
    return
  let name = modifier.stringVal.toLowerAscii()
  if not ModifierTable.hasKey(name):
    log "Invalid key configuration: \"" & modifier.stringVal & "\" is not a valid key modifier", lvlError
    return
  result = some(ModifierTable[name])

proc bitorModifiers(modifiers: openarray[TomlValueRef]): Option[uint32] =
  ## None if any modifier is invalid: a partly parsed combo would bind the wrong keys.
  var mask = 0'u32
  for tomlElement in modifiers:
    let bit = getModifierMask(tomlElement)
    if bit.isNone:
      return
    mask = mask or bit.get
  result = some(mask)

proc getModifiersForAction(configTable: TomlTable): seq[TomlValueRef] =
  if configTable.hasKey("modifiers"):
    let modifiersConfig = configTable["modifiers"]
    if modifiersConfig.kind != TomlValueKind.Array:
      log "Invalid key configuration: " & repr(modifiersConfig) & " is not an array", lvlError
      raise newException(ValueError, "modifiers must be an array of strings")
    return modifiersConfig.arrayVal

proc getKeysForAction(configTable: TomlTable, action: string): seq[string] =
  if not configTable.hasKey("keys"):
    log "\"keys\" not found in config table for action \"" & action & "\"", lvlError
    return
  let tomlKeys = configTable["keys"]
  if tomlKeys.kind != TomlValueKind.Array:
    log "Invalid key config for action: " & action & "\n\"keys\" must be an array of strings", lvlError
    return

  for tomlKey in tomlKeys.arrayVal:
    if tomlKey.kind != TomlValueKind.String:
      log "Invalid key configuration: " & repr(tomlKey) & " is not a string", lvlError
      return
    result.add(tomlKey.stringVal)

proc getKeyCombos(configTable: TomlTable, action: string): seq[KeyCombo] =
  ## Gets the KeyCombos associated with the given `action` from the table.
  let keys = getKeysForAction(configTable, action)
  let modifiers = bitorModifiers(getModifiersForAction(configTable))
  if modifiers.isNone:
    log "Skipping the key bindings of action \"" & action & "\": invalid modifier", lvlError
    return
  for key in keys:
    if key.toKeysym() == NoSymbol:
      log "Unknown key name in config: \"" & key & "\" (action \"" & action & "\")", lvlError
      continue
    result.add((key, modifiers.get))

proc populateControlAction(
  this: Config, binding: Binding, configTable: TomlTable, whileLocked = false
) =
  let
    action = binding.name
    keyCombos = getKeyCombos(configTable, action)
  for keyCombo in keyCombos:
    if this.actionIdentifierTable.hasKey(action):
      this.registerCombo(keyCombo, this.actionIdentifierTable[action], binding, whileLocked)
    else:
      raise newException(Exception, "Invalid key config action: \"" & action & "\" does not exist")

proc runCommand(this: Config, cmd: string) =
  if not spawnShell(cmd):
    log "Failed to start command: " & cmd, lvlWarn

proc runCommands(this: Config, commands: varargs[string]) =
  for cmd in commands:
    this.runCommand(cmd)

proc getAutostartCommands(configTable: TomlTable): seq[string] =
  if not configTable.hasKey("autostart"):
    return
  let autoStartTable = configTable["autostart"]
  if autoStartTable.kind != TomlValueKind.Table:
    raise newException(Exception,"Invalid autostart table")

  if not autoStartTable.tableVal[].hasKey("exec"):
    raise newException(Exception, "Autostart table does not have exec key")

  let execArray = autoStartTable.tableVal[]["exec"]
  if execArray.kind != TomlValueKind.Array:
    raise newException(Exception, "autostart exec must be an array of strings")
  for cmd in execArray.arrayVal:
    if cmd.kind == TomlValueKind.String:
      result.add(cmd.stringVal)
    else:
      log repr(cmd) & " is not a string", lvlWarn

proc runAutostartCommands*(this: Config, configTable: TomlTable) =
  this.runCommands(getAutostartCommands(configTable))

proc runCommandWithArgs(this: Config, command: string, arguments: varargs[string]) =
  var cmd = command.replace("%0", arguments.join " ")
  for i, argument in arguments:
    cmd = cmd.replace("%" & $(i + 1), argument)
  this.runCommand(cmd)

proc populateAppRules*(this: Config, configTable: TomlTable) =
  guarded "appRule":
    this.appRules = configTable.parseAppRules()

proc configureExternalProcess(this: Config, command: string) =
  this.actionIdentifierTable[command] =
    proc(keyCombo: KeyCombo) =
      this.runCommands(command)

proc populateMonitorSettings(this: Config, configTable: TomlTable) =
  if not configTable.hasKey("monitors"):
    return

  let monitorsTable = configTable["monitors"]
  if monitorsTable.kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid monitors config table")

  # Change default monitor settings.
  if monitorsTable.hasKey("default"):
    let changedDefaults = monitorsTable["default"]
    if changedDefaults.kind == TomlValueKind.Table and changedDefaults.hasKey("tags"):
      let tagsTable = changedDefaults["tags"]
      if tagsTable.kind == TomlValueKind.Table:
        guarded "[monitors.default.tags]":
          this.defaultMonitorSettings.tagSettings.populateTagSettings(tagsTable.tableVal)

  # Populate settings per-monitor
  for monitorIDStr, settingsToml in monitorsTable.tableVal.pairs():
    if monitorIDStr == "default":
      continue

    if settingsToml.kind != TomlValueKind.Table:
      log "Settings table incorrect type for monitor ID: " & monitorIDStr, lvlError
      continue

    # Parse the ID into a integer.
    var monitorID: MonitorID
    try:
      monitorID = parseInt(monitorIDStr)
    except ValueError:
      log "Invalid monitor ID: " & monitorIDStr, lvlError
      continue

    var monitorSettings: MonitorSettings = deepcopy this.defaultMonitorSettings

    if settingsToml.hasKey("tags"):
      let tagsTable = settingsToml["tags"]
      if tagsTable.kind == TomlValueKind.Table:
        guarded "[monitors." & monitorIDStr & ".tags]":
          monitorSettings.tagSettings.populateTagSettings(tagsTable.tableVal)

    this.monitorSettings[monitorID] = monitorSettings

proc populateControlsTable(this: Config, configTable: TomlTable) =
  if not configTable.hasKey("controls"):
    return
  # Populate window manager controls
  let controlsTable = configTable["controls"]
  if controlsTable.kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid controls config table")

  for action, controlToml in controlsTable.tableVal.pairs():
    let commandOpt = parseCommand(action)
    if commandOpt.isNone:
      log "Invalid control: " & action, lvlError
    elif controlToml.kind != TomlValueKind.Table:
      log "Invalid control \"" & action & "\": expected a table with keys and modifiers", lvlError
    else:
      guarded "control \"" & action & "\"":
        this.populateControlAction(
          Binding(name: ($(commandOpt.get)).toLower()), controlToml.tableVal[]
        )

proc populateExternalProcessSettings(this: Config, configTable: TomlTable) =
  if not configTable.hasKey("startProcess"):
    return

  # Populate external commands
  let externalProcessesTable = configTable["startProcess"]

  if externalProcessesTable.kind != TomlValueKind.Array:
    raise newException(Exception, "No \"startProcess\" commands defined!")

  for commandDeclaration in externalProcessesTable.arrayVal:
    guarded "startProcess":
      if commandDeclaration.kind != TomlValueKind.Table:
        raise newException(Exception, "Invalid \"startProcess\" configuration command!")
      let declaration = commandDeclaration.tableVal
      let commandOpt = declaration.getStr("command")
      if commandOpt.isNone:
        raise newException(Exception, "Invalid \"startProcess\" configuration: Missing \"command\" string!")
      let command = commandOpt.get

      if declaration.hasKey("clickRegion"):
        let clickRegionOpt = declaration.getInt("clickRegion")
        if clickRegionOpt.isNone:
          raise newException(
            Exception,
            "Invalid \"startProcess\" configuration: \"clickRegion\" not a number!"
          )
        closureScope:
          let command = command
          this.regionClickActionTable[clickRegionOpt.get] =
            proc(idx: int, width: int, regionCord: Point[int], clickCord: Point[int], button: int) =
              this.runCommandWithArgs(
                command,
                $idx,
                $regionCord.x,
                $regionCord.y,
                $clickCord.x,
                $clickCord.y,
                $width,
                $button
              )
      else:
        this.configureExternalProcess(command)
        this.populateControlAction(
          Binding(
            name: command, isProcess: true,
            description: declaration.getStr("description").get("")
          ),
          declaration[], declaration.getBool("whileLocked").get(false)
        )

proc removeTransparencyFromHexColor(color: int): int =
  return color or (0xff shl 24)

proc populateLayoutSettings*(
  this: Config,
  layoutSettings: var LayoutSettings,
  settingsTable: TomlTableRef
) =
  setIfSome layoutSettings.gapSize, settingsTable.getInt("gapSize").map(proc(v: int): uint = max(0, v).uint)
  setIfSome layoutSettings.outerGap, settingsTable.getInt("outerGap").map(proc(v: int): uint = max(0, v).uint)
  setIfSome layoutSettings.resizeStep, settingsTable.getInt("resizeStep", 1).map(proc(v: int): uint = v.uint)

proc populateBarSettings*(this: Config, barSettings: var BarSettings, settingsTable: TomlTableRef) =
  let wtp = settingsTable.getStr("windowTitlePosition")
  if wtp.isSome:
    case wtp.get.toLowerAscii()
    of "center", "centre":
      barSettings.windowTitlePosition = wtpCenter
    of "left":
      barSettings.windowTitlePosition = wtpLeft
    else:
      log "windowTitlePosition needs to be: center, centre, or left!", lvlWarn

  setIfSome barSettings.bgColor, settingsTable.getHex("barBackgroundColor")
  setIfSome barSettings.fgColor, settingsTable.getHex("barForegroundColor")
  setIfSome barSettings.selectionColor, settingsTable.getHex("barSelectionColor")
  setIfSome barSettings.urgentColor, settingsTable.getHex("barUrgentColor")

  let menuBorderColor = settingsTable.getHex("menuBorderColor")
  barSettings.menuBorderColor =
    if menuBorderColor.isSome: menuBorderColor.get else: barSettings.selectionColor

  let hasWindowsColor = settingsTable.getHex("barHasWindowsColor")
  barSettings.hasWindowsColor =
    if hasWindowsColor.isSome: hasWindowsColor.get else: barSettings.fgColor

  let transparency = settingsTable.getInt("barTransparency")
  barSettings.transparency = if transparency.isSome: clamp(transparency.get, 0, 255).uint8 else: 255
  setIfSome barSettings.showIndicator, settingsTable.getBool("barShowIndicator")

  for (key, field) in [("trayIconPadding", addr barSettings.trayIconPadding),
                       ("trayIconSpacing", addr barSettings.trayIconSpacing),
                       ("menuWidthMin", addr barSettings.menuWidthMin),
                       ("barTagPadding", addr barSettings.tagPadding),
                       ("barHeight", addr barSettings.height)]:
    let value = settingsTable.getInt(key)
    if value.isSome:
      field[] = max(0, value.get).uint

  if settingsTable.hasKey("barFonts"):
    let barFonts = settingsTable["barFonts"]
    if barFonts.kind != TomlValueKind.Array:
      log "barFonts is not an array of strings!", lvlWarn
    else:
      var fonts: seq[string]
      for font in barFonts.arrayVal:
        if font.kind == TomlValueKind.String:
          fonts.add(font.stringVal)
        else:
          log "Invalid font - must be a string!", lvlWarn
      if fonts.len > 0:
        barSettings.fonts = fonts
      else:
        log "barFonts has no valid font; keeping the default", lvlWarn

proc populateGeneralSettings*(this: Config, configTable: TomlTable) =
  if not configTable.hasKey("settings") or configTable["settings"].kind != TomlValueKind.Table:
    log "Missing or invalid [settings] table; using defaults", lvlError
    return

  let settingsTable = configTable["settings"].tableVal
  guarded "bar settings":
    this.populateBarSettings(this.defaultMonitorSettings.barSettings, settingsTable)
  guarded "layout settings":
    this.populateLayoutSettings(this.defaultMonitorSettings.layoutSettings, settingsTable)

  # Window settings
  setIfSome this.windowSettings.borderWidth,
    settingsTable.getInt("borderWidth").map(proc(v: int): uint = max(0, v).uint)
  for (key, field) in [("floatingWidth", addr this.windowSettings.floatingWidth),
                       ("floatingHeight", addr this.windowSettings.floatingHeight)]:
    let percent = settingsTable.getInt(key, 10)
    if percent.isSome:
      field[] = min(percent.get, 100)
  setIfSome this.windowSettings.floatingStep, settingsTable.getInt("floatingStep", 1)
  for (key, field) in [("borderColorUnfocused", addr this.windowSettings.borderColorUnfocused),
                       ("borderColorFocused", addr this.windowSettings.borderColorFocused),
                       ("borderColorUrgent", addr this.windowSettings.borderColorUrgent)]:
    let color = settingsTable.getHex(key)
    if color.isSome:
      field[] = removeTransparencyFromHexColor(color.get)

  # Bar & layout settings
  for monitorSettings in this.monitorSettings.mvalues():
    guarded "monitor settings":
      this.populateBarSettings(monitorSettings.barSettings, settingsTable)
      this.populateLayoutSettings(monitorSettings.layoutSettings, settingsTable)

  # General settings
  setIfSome this.loggingEnabled, settingsTable.getBool("loggingEnabled")
  setIfSome this.trayEnabled, settingsTable.getBool("trayEnabled")
  setIfSome this.trayMonitor, settingsTable.getInt("trayMonitor").map(proc(v: int): int = max(0, v))
  setIfSome this.trayIconTheme, settingsTable.getStr("trayIconTheme")
  setIfSome this.lockCommand, settingsTable.getStr("lockCommand")
  setIfSome this.hotkeyOverlayAtStartup, settingsTable.getBool("hotkeyOverlayAtStartup")
  setIfSome this.reverseTagScrolling, settingsTable.getBool("reverseTagScrolling")

  # Scratchpad settings
  setIfSome this.scratchpadSettings.width, settingsTable.getInt("scratchpadWidth")
  setIfSome this.scratchpadSettings.height, settingsTable.getInt("scratchpadHeight")

  let modKey = settingsTable.getStr("modKey")
  if modKey.isSome:
    let name = modKey.get.toLowerAscii()
    if ModifierTable.hasKey(name):
      this.windowSettings.modKey = ModifierTable[name].int
    else:
      log "modKey \"" & modKey.get & "\" is not a valid modifier; keeping the default", lvlWarn

proc populateInputSettings*(this: Config, configTable: TomlTable) =
  ## The optional [input.keyboard], [input.touchpad] and [input.mouse] tables.
  this.input = InputSettings()
  if not configTable.hasKey("input") or configTable["input"].kind != TomlValueKind.Table:
    return
  let input = configTable["input"].tableVal

  proc section(name: string): TomlTableRef =
    if input.hasKey(name):
      if input[name].kind == TomlValueKind.Table:
        return input[name].tableVal
      log "[input." & name & "] is not a table", lvlWarn
    newTTable().tableVal

  let keyboard = section("keyboard")
  this.input.keyboard = KeyboardSettings(
    layout: keyboard.getStr("layout"),
    variant: keyboard.getStr("variant"),
    options: keyboard.getStr("options"),
    model: keyboard.getStr("model"),
    repeatRate: keyboard.getInt("repeatRate", 0),
    repeatDelay: keyboard.getInt("repeatDelay", 0),
    numlock: keyboard.getBool("numlock")
  )
  proc pointerSettings(t: TomlTableRef, touchpad: bool): PointerSettings =
    result = PointerSettings(
      naturalScroll: t.getBool("naturalScroll"),
      accelSpeed: t.getFloat("accelSpeed", -1.0, 1.0),
      accelProfile: getEnum[AccelProfile](t, "accelProfile")
    )
    if touchpad:
      result.tap = t.getBool("tap")
      result.disableWhileTyping = t.getBool("disableWhileTyping")
      result.clickMethod = getEnum[ClickMethod](t, "clickMethod")
      result.scrollMethod = getEnum[ScrollMethod](t, "scrollMethod")
    else:
      result.leftHanded = t.getBool("leftHanded")
  this.input.touchpad = section("touchpad").pointerSettings(true)
  this.input.mouse = section("mouse").pointerSettings(false)

proc populateKeyComboTable*(this: Config, configTable: TomlTable) =
  ## Reads the user's configuration file and set the keybindings.
  guarded "controls":
    this.populateControlsTable(configTable)
  guarded "monitors":
    this.populateMonitorSettings(configTable)
  guarded "startProcess":
    this.populateExternalProcessSettings(configTable)

proc load*(this: Config, configTable: TomlTable) =
  ## Populates the whole config. Never raises: bad entries are logged and skipped.
  ## Actions (`configureAction`) must be registered first, as controls refer to them.
  this.populateAppRules(configTable)
  this.populateKeyComboTable(configTable)
  this.populateGeneralSettings(configTable)
  guarded "input settings":
    this.populateInputSettings(configTable)

proc parseConfig*(text: string): TomlTable =
  let loadedConfig = parsetoml.parseString(text)
  if loadedConfig.kind != TomlValueKind.Table:
    raise newException(ValueError, "Invalid config file!")
  loadedConfig.tableVal[]

proc loadConfigFile*(strict = false): TomlTable =
  ## Reads the user's configuration file into a table.
  ## Set configLoc before calling this procedure,
  ## if you would like to use an alternate config file.
  ##
  ## Unless `strict`, a missing or unparsable file is logged and the embedded
  ## default config is returned, so there are always key bindings. With `strict`
  ## the error is raised instead (e.g. to keep the running config on reload).
  if configLoc.len == 0:
    configLoc = findConfigPath()
  try:
    if configLoc.len == 0:
      return parseConfig(embeddedDefaultConfig)
    return parseConfig(readFile(configLoc))
  except Exception:
    if strict:
      raise
    log "Failed to load config \"" & configLoc & "\": " & getCurrentExceptionMsg() &
      "; using the built-in default config", lvlError
    result = parseConfig(embeddedDefaultConfig)
