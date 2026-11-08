import
  nimtest,
  os,
  parsetoml,
  tables,
  config/configloader,
  config/keys,
  tag

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
    assert config.defaultMonitorSettings.barSettings.hasWindowsColor == 0xfce8c3

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
    assert bar.bgColor == 0x1c1b19
    assert bar.fgColor == 0xfce8c3
    assert bar.height == 20
    assert bar.transparency == 255
    assert bar.showIndicator
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
