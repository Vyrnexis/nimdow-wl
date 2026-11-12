import
  std/options,
  parsetoml,
  strutils

import
  ../wm/tags,
  ../sys/logger

type
  TagSettings* = OrderedTable[TagID, TagSetting]

proc createDefaultTagSettings*(): TagSettings =
  for i in 1..tagCount:
    result[i] = newTagSetting($i, 1, 50)

type TagOverrides = object
  ## The keys a `[tags.*]` table sets; unset keys leave the tag as it is.
  displayString: Option[string]
  numMasterWindows, defaultMasterWidthPercentage: Option[int]

proc parseOverrides(settingsTable: TomlTableRef): TagOverrides =
  if settingsTable.hasKey("displayString"):
    let displayString = settingsTable["displayString"]
    if displayString.kind != TomlValueKind.String:
      raise newException(ValueError, "Invalid displayString for tag")
    result.displayString = some(displayString.stringVal)

  if settingsTable.hasKey("numMasterWindows"):
    let numMasterWindows = settingsTable["numMasterWindows"]
    if numMasterWindows.kind != TomlValueKind.Int:
      raise newException(ValueError, "Invalid numMasterWindows for tag")
    if numMasterWindows.intVal < 1:
      raise newException(ValueError, "numMasterWindows must be at least 1")
    result.numMasterWindows = some(numMasterWindows.intVal.int)

  if settingsTable.hasKey("defaultMasterWidthPercentage"):
    let masterWidthSetting = settingsTable["defaultMasterWidthPercentage"]
    if masterWidthSetting.kind != TomlValueKind.Int:
      raise newException(ValueError, "invalid defaultMasterWidthPercentage for tag")
    let percentage = masterWidthSetting.intVal.int.clamp(10, 90)
    if percentage != masterWidthSetting.intVal:
      log "Invalid defaultMasterWidthPercentage, clamped to 10-90%", lvlWarn
    result.defaultMasterWidthPercentage = some(percentage)

proc applyTo(overrides: TagOverrides, setting: TagSetting) =
  if overrides.displayString.isSome:
    setting.displayString = overrides.displayString.get
  if overrides.numMasterWindows.isSome:
    setting.numMasterWindows = overrides.numMasterWindows.get
  if overrides.defaultMasterWidthPercentage.isSome:
    setting.defaultMasterWidthPercentage = overrides.defaultMasterWidthPercentage.get

proc populateTagSettings*(settings: var TagSettings, tagSettingsTable: TomlTableRef) =
  ## Applies the `[tags]` tables. A bad tag is logged and skipped (the rest is
  ## still applied). TagSetting is a ref, so changes are made in place.
  if tagSettingsTable.hasKey("all"):
    let allTagSettingsTable = tagSettingsTable["all"]
    if allTagSettingsTable.kind != TomlValueKind.Table:
      log "Settings table incorrect type for tag ID: all", lvlError
    else:
      try:
        let overrides = parseOverrides(allTagSettingsTable.tableVal)
        for setting in settings.mvalues:
          overrides.applyTo(setting)
      except ValueError:
        log "Invalid tag settings for \"all\": " & getCurrentExceptionMsg(), lvlError

  for tagIDstr, settingsToml in tagSettingsTable.pairs():
    # Special case handled above.
    if tagIDstr == "all":
      continue

    if settingsToml.kind != TomlValueKind.Table:
      log "Settings table incorrect type for tag ID: " & tagIDstr, lvlError
      continue

    var tagID: int
    try:
      tagID = parseInt(tagIDstr)
    except ValueError:
      log "Invalid tag id: " & tagIDstr, lvlError
      continue
    if tagID < 1 or tagID > tagCount:
      log "Tag id " & tagIDstr & " is out of range (1-" & $tagCount & ")", lvlError
      continue

    try:
      parseOverrides(settingsToml.tableVal).applyTo(settings[tagID])
    except ValueError:
      log "Invalid settings for tag " & tagIDstr & ": " & getCurrentExceptionMsg(), lvlError
