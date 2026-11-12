import
  nimtest,
  os,
  parsetoml,
  sets,
  tables,
  config/configloader,
  config/keys,
  wm/clientlist,
  wm/commands

proc noop(keyCombo: KeyCombo) = discard

proc configWithActions(): Config =
  result = newConfig()
  for action in ["focusprevious", "focusnext", "killclient"]:
    result.configureAction(action, noop)

proc loaded(toml: string): Config =
  result = configWithActions()
  result.load(parseConfig(toml))

describe "Config key bindings":

  it "skips a binding with an invalid modifier instead of binding the bare key":
    let config = loaded """
    [controls.focusPrevious]
    keys = [ "k" ]
    modifiers = [ "Supr" ]

    [controls.focusNext]
    keys = [ "j" ]
    modifiers = [ "super", "shift" ]
    """
    assert config.keyComboTable.len == 1
    assert config.keyComboTable.hasKey(("j", ModifierTable["super"] or ModifierTable["shift"]))

  it "accepts modifier names in any case":
    let config = loaded """
    [controls.focusPrevious]
    keys = [ "k" ]
    modifiers = [ "Super" ]
    """
    assert config.keyComboTable.hasKey(("k", ModifierTable["super"]))

  it "keeps loading after a malformed control":
    let config = loaded """
    [controls]
    focusNext = 1

    [controls.focusPrevious]
    keys = [ "k" ]
    modifiers = [ "super" ]

    [controls.notAnAction]
    keys = [ "x" ]
    """
    assert config.keyComboTable.len == 1
    assert config.keyComboTable.hasKey(("k", ModifierTable["super"]))

  it "does not raise on malformed sections":
    let config = loaded """
    controls = 3
    monitors = "x"
    startProcess = 4
    appRule = 5
    settings = 6
    """
    assert config.defaultMonitorSettings.tagSettings.len == tagCount

  it "keeps one binding for keys that differ only in spelling":
    let config = loaded """
    [controls.focusPrevious]
    keys = [ "r", "R" ]
    modifiers = [ "super" ]

    [controls.focusNext]
    keys = [ "Return", "return" ]
    modifiers = [ "super" ]
    """
    assert config.keyComboTable.len == 2

  it "has monitor defaults without any config":
    let config = newConfig()
    assert config.defaultMonitorSettings.tagSettings.len == tagCount
    assert config.defaultMonitorSettings.barSettings.height == 20
    assert config.defaultMonitorSettings.barSettings.transparency == 255

describe "Config loading":

  it "has the built-in defaults of config.default.toml":
    let text = readFile(currentSourcePath().parentDir / ".." / ".." / ".." / "config.default.toml")
    let fromFile = loaded(text)
    let builtIn = loaded ""
    assert fromFile.windowSettings == builtIn.windowSettings
    assert fromFile.scratchpadSettings == builtIn.scratchpadSettings
    let a = fromFile.defaultMonitorSettings
    let b = builtIn.defaultMonitorSettings
    assert a.barSettings == b.barSettings
    assert a.layoutSettings == b.layoutSettings
    assert a.tagSettings.len == b.tagSettings.len
    for id, setting in a.tagSettings.pairs:
      assert setting[] == b.tagSettings[id][]
    assert (fromFile.loggingEnabled, fromFile.trayEnabled, fromFile.trayMonitor,
      fromFile.trayIconTheme, fromFile.lockCommand, fromFile.hotkeyOverlayAtStartup,
      fromFile.reverseTagScrolling) == (builtIn.loggingEnabled, builtIn.trayEnabled,
      builtIn.trayMonitor, builtIn.trayIconTheme, builtIn.lockCommand,
      builtIn.hotkeyOverlayAtStartup, builtIn.reverseTagScrolling)

  it "ignores settings and controls that were removed":
    let config = loaded """
    [settings]
    borderColorUrgent = "#ff5555"
    barUrgentColor = "#ff5555"
    barHeight = 25

    [controls.jumpToUrgentWindow]
    keys = [ "u" ]
    modifiers = [ "super" ]

    [controls.focusNext]
    keys = [ "j" ]
    modifiers = [ "super" ]
    """
    assert config.defaultMonitorSettings.barSettings.height == 25
    assert config.keyComboTable.len == 1

  it "warns about and skips negative sizes":
    let config = loaded """
    [settings]
    gapSize = -5
    barHeight = -1
    borderWidth = -2
    """
    assert config.defaultMonitorSettings.layoutSettings.gapSize == 12
    assert config.defaultMonitorSettings.barSettings.height == 20
    assert config.windowSettings.borderWidth == 1

  it "gives each clickRegion its own command":
    let config = loaded """
    [[startProcess]]
    command = "true a"
    clickRegion = 1

    [[startProcess]]
    command = "true b"
    clickRegion = 2
    """
    assert config.regionClickActionTable.len == 2

  it "falls back to the embedded default config when the file does not parse":
    let path = getTempDir() / "nimdow-wl-test-broken.toml"
    writeFile(path, "[settings\nthis is = = not toml")
    defer: removeFile(path)
    let saved = configLoc
    defer: configLoc = saved
    configLoc = path
    let table = loadConfigFile()
    assert table.hasKey("controls")
    assert table.hasKey("settings")
    var raised = false
    try:
      discard loadConfigFile(strict = true)
    except Exception:
      raised = true
    assert raised

  it "falls back to the embedded default config when the file is missing":
    let saved = configLoc
    defer: configLoc = saved
    configLoc = getTempDir() / "nimdow-wl-test-does-not-exist.toml"
    assert loadConfigFile().hasKey("controls")

  it "binds keys from the embedded default config":
    let config = newConfig()
    config.configureAction("killclient", noop)
    let saved = configLoc
    defer: configLoc = saved
    configLoc = getTempDir() / "nimdow-wl-test-does-not-exist.toml"
    config.load(loadConfigFile())
    assert config.keyComboTable.len > 0

describe "Config settings":

  it "falls back to the foreground color for the has-windows color":
    var config = loaded """
    [settings]
    barForegroundColor = "ff0000"
    """
    assert config.defaultMonitorSettings.barSettings.fgColor == 0xff0000
    assert config.defaultMonitorSettings.barSettings.hasWindowsColor == 0xff0000
    config = loaded """
    [settings]
    barForegroundColor = "ff0000"
    barHasWindowsColor = "00ff00"
    """
    assert config.defaultMonitorSettings.barSettings.hasWindowsColor == 0x00ff00
    config = loaded "[settings]\n"
    assert config.defaultMonitorSettings.barSettings.hasWindowsColor == 0xf8f8f2

  it "accepts colors with a leading #":
    let config = loaded """
    [settings]
    barBackgroundColor = "#102030"
    """
    assert config.defaultMonitorSettings.barSettings.bgColor == 0x102030

  it "keeps the defaults for bad values":
    let config = loaded """
    [settings]
    barBackgroundColor = "nothex"
    barForegroundColor = 5
    barHeight = "tall"
    barTransparency = "x"
    barShowIndicator = "yes"
    windowTitlePosition = "middle"
    barFonts = [ 1, 2 ]
    gapSize = "big"
    resizeStep = 0
    """
    let bar = config.defaultMonitorSettings.barSettings
    assert bar.bgColor == 0x282a36
    assert bar.fgColor == 0xf8f8f2
    assert bar.height == 20
    assert bar.transparency == 255
    assert not bar.showIndicator
    assert bar.fonts.len == 2
    assert config.defaultMonitorSettings.layoutSettings.gapSize == 12
    assert config.defaultMonitorSettings.layoutSettings.resizeStep == 10

  it "applies good values next to bad ones":
    let config = loaded """
    [settings]
    barHeight = 30
    gapSize = "big"
    outerGap = 4
    trayIconTheme = "Papirus"
    """
    assert config.defaultMonitorSettings.barSettings.height == 30
    assert config.defaultMonitorSettings.layoutSettings.outerGap == 4
    assert config.trayIconTheme == "Papirus"

  it "reads the floating settings and keeps the defaults for bad values":
    var config = loaded "[settings]\n"
    assert (config.windowSettings.floatingWidth, config.windowSettings.floatingHeight,
      config.windowSettings.floatingStep) == (50, 50, 40)
    config = loaded """
    [settings]
    floatingWidth = 70
    floatingHeight = 300
    floatingStep = 25
    """
    assert (config.windowSettings.floatingWidth, config.windowSettings.floatingHeight,
      config.windowSettings.floatingStep) == (70, 100, 25)
    config = loaded """
    [settings]
    floatingWidth = 0
    floatingHeight = "tall"
    floatingStep = 0
    """
    assert (config.windowSettings.floatingWidth, config.windowSettings.floatingHeight,
      config.windowSettings.floatingStep) == (50, 50, 40)

  it "survives an unknown modKey":
    var config = loaded """
    [settings]
    modKey = "Hyper"
    """
    assert config.windowSettings.modKey == ModifierTable["super"].int
    config = loaded """
    [settings]
    modKey = "Alt"
    """
    assert config.windowSettings.modKey == ModifierTable["alt"].int

  it "applies monitor tag settings and skips out-of-range tags":
    let config = loaded """
    [settings]

    [monitors.1.tags.2]
    displayString = "two"

    [monitors.1.tags.99]
    displayString = "nope"
    """
    assert config.monitorSettings[1].tagSettings[2].displayString == "two"
    assert config.defaultMonitorSettings.tagSettings[2].displayString == "2"

describe "Config lookup and first-run copy":

  proc tempRoot(name: string): string =
    result = getTempDir() / ("nimdow-wl-test-" & name & "-" & $getCurrentProcessId())
    removeDir(result)
    createDir(result)

  it "finds the first system config in XDG_CONFIG_DIRS":
    let root = tempRoot("sys")
    defer: removeDir(root)
    createDir(root / "b" / "nimdow-wl")
    writeFile(root / "b" / "nimdow-wl" / "config.toml", "# b")
    createDir(root / "c" / "nimdow-wl")
    writeFile(root / "c" / "nimdow-wl" / "config.toml", "# c")
    assert findSystemConfig(root / "a:" & root / "b:" & root / "c") == root / "b" / "nimdow-wl" / "config.toml"
    assert findSystemConfig(root / "a") == ""

  it "copies the system config to the user path and creates directories":
    let root = tempRoot("copy")
    defer: removeDir(root)
    let source = root / "sys.toml"
    writeFile(source, "# system")
    let user = root / "home" / "nimdow-wl" / "config.toml"
    assert seedUserConfig(user, source) == user
    assert readFile(user) == "# system"

  it "writes the embedded default when there is no source":
    let root = tempRoot("embedded")
    defer: removeDir(root)
    let user = root / "nimdow-wl" / "config.toml"
    assert seedUserConfig(user, "", "# embedded") == user
    assert readFile(user) == "# embedded"

  it "never overwrites an existing user config":
    let root = tempRoot("keep")
    defer: removeDir(root)
    let source = root / "sys.toml"
    writeFile(source, "# system")
    let user = root / "config.toml"
    writeFile(user, "# mine")
    assert seedUserConfig(user, source) == user
    assert readFile(user) == "# mine"

  it "keeps using the source when the copy fails":
    let root = tempRoot("fail")
    defer: removeDir(root)
    let source = root / "sys.toml"
    writeFile(source, "# system")
    writeFile(root / "file", "")  # a file where a directory is needed
    assert seedUserConfig(root / "file" / "nimdow-wl" / "config.toml", source) == source
    assert seedUserConfig(root / "file" / "nimdow-wl" / "config.toml", "") == ""

  it "findConfigPath seeds XDG_CONFIG_HOME from XDG_CONFIG_DIRS":
    let root = tempRoot("find")
    defer: removeDir(root)
    createDir(root / "etc" / "nimdow-wl")
    writeFile(root / "etc" / "nimdow-wl" / "config.toml", "# etc")
    let savedHome = getEnv("XDG_CONFIG_HOME")
    let savedDirs = getEnv("XDG_CONFIG_DIRS")
    defer:
      putEnv("XDG_CONFIG_HOME", savedHome)
      putEnv("XDG_CONFIG_DIRS", savedDirs)
      if savedHome.len == 0: delEnv("XDG_CONFIG_HOME")
      if savedDirs.len == 0: delEnv("XDG_CONFIG_DIRS")
    putEnv("XDG_CONFIG_HOME", root / "home")
    putEnv("XDG_CONFIG_DIRS", root / "etc")
    let expected = root / "home" / "nimdow-wl" / "config.toml"
    assert findConfigPath() == expected
    assert readFile(expected) == "# etc"

describe "Input settings":

  it "leaves everything unset without an [input] section":
    let input = loaded("").input
    assert input.keyboard.layout.isNone and input.keyboard.repeatRate.isNone
    assert input.touchpad.tap.isNone and input.mouse.accelSpeed.isNone

  it "parses every key":
    let input = loaded("""
    [input.keyboard]
    layout = "us,de"
    variant = ""
    options = "caps:escape"
    model = "pc105"
    repeatRate = 30
    repeatDelay = 300
    numlock = true

    [input.touchpad]
    tap = true
    naturalScroll = true
    disableWhileTyping = false
    accelSpeed = 0.5
    accelProfile = "Flat"
    clickMethod = "buttonareas"
    scrollMethod = "edge"

    [input.mouse]
    naturalScroll = false
    accelSpeed = -1
    accelProfile = "adaptive"
    leftHanded = true
    """).input
    assert input.keyboard.layout == some("us,de")
    assert input.keyboard.variant == some("")
    assert input.keyboard.options == some("caps:escape")
    assert input.keyboard.model == some("pc105")
    assert input.keyboard.repeatRate == some(30)
    assert input.keyboard.repeatDelay == some(300)
    assert input.keyboard.numlock == some(true)
    assert input.touchpad.tap == some(true)
    assert input.touchpad.naturalScroll == some(true)
    assert input.touchpad.disableWhileTyping == some(false)
    assert input.touchpad.accelSpeed == some(0.5)
    assert input.touchpad.accelProfile == some(apFlat)
    assert input.touchpad.clickMethod == some(cmButtonAreas)
    assert input.touchpad.scrollMethod == some(smEdge)
    assert input.mouse.naturalScroll == some(false)
    assert input.mouse.accelSpeed == some(-1.0)
    assert input.mouse.accelProfile == some(apAdaptive)
    assert input.mouse.leftHanded == some(true)

  it "ignores invalid values and keeps the valid ones":
    let input = loaded("""
    [input.keyboard]
    layout = 5
    repeatRate = -1
    repeatDelay = "slow"
    numlock = "yes"
    model = "pc105"

    [input.touchpad]
    tap = 1
    accelSpeed = 2.0
    accelProfile = "custom"
    clickMethod = "palm"
    scrollMethod = 3
    naturalScroll = true

    [input.mouse]
    accelSpeed = "fast"
    accelProfile = true
    """).input
    assert input.keyboard.layout.isNone and input.keyboard.repeatRate.isNone
    assert input.keyboard.repeatDelay.isNone and input.keyboard.numlock.isNone
    assert input.keyboard.model == some("pc105")
    assert input.touchpad.tap.isNone and input.touchpad.accelSpeed.isNone
    assert input.touchpad.accelProfile.isNone and input.touchpad.clickMethod.isNone
    assert input.touchpad.scrollMethod.isNone
    assert input.touchpad.naturalScroll == some(true)
    assert input.mouse.accelSpeed.isNone and input.mouse.accelProfile.isNone

  it "ignores keys of the other device kind and non-table sections":
    let input = loaded("""
    [input]
    keyboard = 1

    [input.touchpad]
    leftHanded = true

    [input.mouse]
    tap = true
    clickMethod = "clickfinger"
    """).input
    assert input.keyboard.layout.isNone
    assert input.touchpad.leftHanded.isNone
    assert input.mouse.tap.isNone and input.mouse.clickMethod.isNone

  it "reloading drops the settings that were removed":
    let config = loaded("[input.touchpad]\ntap = true")
    assert config.input.touchpad.tap == some(true)
    config.load(parseConfig(""))
    assert config.input.touchpad.tap.isNone

describe "Screen lock config":

  it "defaults lockCommand and reads it from [settings]":
    assert newConfig().lockCommand == "swaylock -f -c 282828"
    let config = loaded """
    [settings]
    lockCommand = "gtklock"
    """
    assert config.lockCommand == "gtklock"

  it "marks only the startProcess entries with whileLocked = true":
    let config = loaded """
    [[startProcess]]
    command = "a"
    keys = [ "F1" ]
    modifiers = []
    whileLocked = true

    [[startProcess]]
    command = "b"
    keys = [ "F2" ]
    modifiers = []
    whileLocked = false

    [[startProcess]]
    command = "c"
    keys = [ "F3" ]
    modifiers = []
    """
    assert config.keyComboTable.len == 3
    assert config.whileLockedCombos == [("F1", 0'u32)].toHashSet

  it "registers the lockSession control":
    let config = newConfig()
    config.configureAction($wmcLockSession, noop)
    config.load(parseConfig """
    [controls.lockSession]
    keys = [ "Escape" ]
    modifiers = [ "super" ]
    """)
    assert config.keyComboTable.hasKey(("Escape", ModifierTable["super"]))

describe "Desktop package config":

  it "parses and wires the desktop programs":
    let text = readFile(currentSourcePath().parentDir / ".." / ".." / ".." / "packaging" / "desktop" / "config.toml")
    let table = parseConfig(text)
    let config = newConfig()
    for command in WMCommand:
      config.configureAction($command, noop)
    config.load(table)
    # Every control resolved to an action (none was skipped as unknown or invalid).
    var expected = 0
    for name, control in table["controls"].tableVal.pairs:
      expected += control["keys"].arrayVal.len
    assert config.keyComboTable.len >= expected
    for region in [1, 2, 4, 7]:
      assert config.regionClickActionTable.hasKey(region), $region
    assert config.input.touchpad.tap == some(true)
    assert config.input.keyboard.layout.isNone and config.input.mouse.accelSpeed.isNone
    assert config.defaultMonitorSettings.barSettings.fonts[0] == "MesloLGS Nerd Font:size=12:antialias=true"
    assert config.defaultMonitorSettings.barSettings.height == 30
    let autostart = table["autostart"]["exec"].arrayVal
    var cmds: seq[string]
    for c in autostart: cmds.add c.stringVal
    assert cmds == @["swaybg -i /usr/share/backgrounds/nimdow-wl/reverie.jpg -m fill -c '#282828'", "mako",
      "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1", "nimdow-wl-status",
      "swayidle -w timeout 600 'swaylock -f -c 282828' timeout 900 'systemctl suspend' before-sleep 'swaylock -f -c 282828'"]
    for key in ["XF86AudioRaiseVolume", "XF86AudioLowerVolume", "XF86AudioMute", "XF86AudioMicMute",
                "XF86MonBrightnessUp", "XF86MonBrightnessDown", "Print"]:
      assert config.keyComboTable.hasKey((key, 0'u32)), key
    for key in ["XF86AudioMute", "XF86MonBrightnessUp"]:
      assert (key, 0'u32) in config.whileLockedCombos, key
    assert ("Print", 0'u32) notin config.whileLockedCombos
    assert config.keyComboTable.hasKey(("Escape", ModifierTable["super"]))
    assert config.lockCommand == "swaylock -f -c 282828"
