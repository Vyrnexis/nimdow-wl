import
  nimtest,
  os,
  sequtils,
  strutils,
  tables,
  config/configloader,
  config/keys,
  wm/commands

# The content helpers are private: include the module to test them.
include bar/overlay

proc noop(keyCombo: KeyCombo) = discard

proc contentOf(file: string): seq[OverlaySection] =
  let text = readFile(currentSourcePath().parentDir / ".." / ".." / ".." / file)
  let config = newConfig()
  for command in WMCommand:
    config.configureAction($command, noop)
  config.load(parseConfig(text))
  overlayContent(config)

proc rows(sections: seq[OverlaySection]): seq[OverlayRow] =
  for section in sections:
    result.add section.rows

const super = ModifierTable["super"]
const shift = ModifierTable["shift"]

describe "Hotkey overlay key formatting":

  it "shows modifiers and a key":
    assert keysText(super or shift, @["j"]) == "Super + Shift + J"
    assert keysText(0, @["XF86AudioRaiseVolume"]) == "Volume up"

  it "uses friendly key names":
    assert keyName("Return") == "Enter"
    assert keyName("space") == "Space"
    assert keyName("XF86MonBrightnessDown") == "Brightness down"
    assert keyName("XF86Unknown") == "Unknown"
    assert keyName("Left") == "Left"

  it "collapses a run of digits":
    let digits = toSeq(1 .. 9).mapIt($it)
    assert keysText(super, digits) == "Super + 1–9"
    assert keysText(super, @["1", "2", "3"]) == "Super + 1–3"

  it "lists keys that are not a run of digits":
    assert keysText(super, @["Left", "Right"]) == "Super + Left / Right"
    assert keysText(super, @["1", "3", "4"]) == "Super + 1 / 3 / 4"
    assert keysText(super, @["1", "2"]) == "Super + 1 / 2"

describe "Hotkey overlay content":

  it "labels every control":
    for command in WMCommand:
      assert info(command).label.len > 0, $command

  it "lists the bindings of the default config in sections":
    let sections = contentOf("config.default.toml")
    assert sections.len > 0
    for section in sections:
      assert section.title.len > 0
      assert section.rows.len > 0, section.title
      for row in section.rows:
        assert row.label.len > 0 and row.keys.len > 0
    let all = rows(sections)
    assert OverlayRow(label: "Go to tag", keys: "Super + 1–9") in all
    assert OverlayRow(label: "Move window to tag", keys: "Super + Shift + 1–9") in all
    assert OverlayRow(label: "Focus next window", keys: "Super + J") in all
    assert OverlayRow(label: "Show key bindings", keys: "Super + /") in all
    # No description: the command is shown.
    assert OverlayRow(label: "alacritty", keys: "Super + Enter") in all

  it "lists the desktop config with its descriptions":
    let sections = contentOf("packaging/desktop/config.toml")
    for section in sections:
      assert section.rows.len > 0, section.title
    let all = rows(sections)
    assert OverlayRow(label: "Terminal", keys: "Super + Enter") in all
    assert OverlayRow(label: "Show key bindings", keys: "Super + /") in all
    var media: seq[OverlayRow]
    for section in sections:
      if section.title == "Media & hardware":
        media = section.rows
    assert OverlayRow(label: "Volume up", keys: "Volume up") in media
    assert OverlayRow(label: "Brightness down", keys: "Brightness down") in media
    # Click regions have no keys: hidden.
    for row in all:
      assert "Arch updates" notin row.label and "nmtui" notin row.label

  it "gives every desktop startProcess with keys a description":
    let table = parseConfig(readFile(
      currentSourcePath().parentDir / ".." / ".." / ".." / "packaging" / "desktop" / "config.toml"))
    for entry in table["startProcess"].arrayVal:
      if entry.tableVal.hasKey("keys"):
        assert entry.tableVal.hasKey("description"), entry.tableVal["command"].stringVal

  it "shortens a long command without description and hides controls without keys":
    let config = newConfig()
    config.configureAction("togglefloating", noop)
    config.load(parseConfig """
    [[startProcess]]
    command = "a-very-long-command --with --many --arguments --that --go --on"
    keys = [ "F1" ]
    modifiers = []

    [controls.toggleFloating]
    keys = []
    modifiers = []
    """)
    let all = rows(overlayContent(config))
    assert all.len == 1
    assert all[0].label.len < 40 and all[0].label.endsWith("…")

  it "reads hotkeyOverlayAtStartup, off by default":
    assert not newConfig().hotkeyOverlayAtStartup
    let config = newConfig()
    config.load(parseConfig "[settings]\nhotkeyOverlayAtStartup = true")
    assert config.hotkeyOverlayAtStartup
