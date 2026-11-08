import
  parsetoml,
  strutils

import
  ../tag,
  ../sys/logger

type
  TagSettings* = OrderedTable[TagID, TagSetting]

proc createDefaultTagSettings*(): TagSettings =
  for i in 1..tagCount:
    result[i] = newTagSetting($i, 1, 50)

proc parseTagSetting(tagSetting: var TagSetting, settingsTable: TomlTableRef) =
  # Check for displayString
  if settingsTable.hasKey("displayString"):
    let displayString = settingsTable["displayString"]
    if displayString.kind != TomlValueKind.String:
      raise newException(ValueError, "Invalid displayString for tag")
    tagSetting.displayString = displayString.stringVal

  # Check for numMasterWindows
  if settingsTable.hasKey("numMasterWindows"):
    let numMasterWindows = settingsTable["numMasterWindows"]
    if numMasterWindows.kind != TomlValueKind.Int:
      raise newException(ValueError, "Invalid numMasterWindows for tag")
    if numMasterWindows.intVal < 1:
      raise newException(ValueError, "numMasterWindows must be at least 1")
    tagSetting.numMasterWindows = numMasterWindows.intVal.int

  if settingsTable.hasKey("defaultMasterWidthPercentage"):
    let masterWidthSetting = settingsTable["defaultMasterWidthPercentage"]
    if masterWidthSetting.kind == TomlValueKind.Int:
      tagSetting.defaultMasterWidthPercentage = masterWidthSetting.intVal.int.clamp(10,90)
      if tagSetting.defaultMasterWidthPercentage != masterWidthSetting.intVal:
        log "Invalid defaultMasterWidthPercentage, clamped to 10-90%", lvlWarn
    else:
      raise newException(ValueError, "invalid defaultMasterWidthPercentage for tag")

proc copyOf(setting: TagSetting): TagSetting =
  newTagSetting(setting.displayString, setting.numMasterWindows, setting.defaultMasterWidthPercentage)

proc populateTagSettings*(settings: var TagSettings, tagSettingsTable: TomlTableRef) =
  ## Applies the `[tags]` tables. A bad tag is logged and skipped (the rest is
  ## still applied). TagSetting is a ref, so changes are made in place.
  if tagSettingsTable.hasKey("all"):
    let allTagSettingsTable = tagSettingsTable["all"]
    if allTagSettingsTable.kind != TomlValueKind.Table:
      log "Settings table incorrect type for tag ID: all", lvlError
    else:
      var allTagSettings = newTagSetting("", int.high, 50)
      try:
        allTagSettings.parseTagSetting(allTagSettingsTable.tableVal)
        for setting in settings.mvalues:
          if allTagSettings.displayString.len > 0:
            setting.displayString = allTagSettings.displayString
          if allTagSettings.numMasterWindows != int.high:
            setting.numMasterWindows = allTagSettings.numMasterWindows
          if allTagSettings.defaultMasterWidthPercentage != 50:
            setting.defaultMasterWidthPercentage = allTagSettings.defaultMasterWidthPercentage
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

    # Parse into a copy so a bad value leaves the tag untouched.
    var scratch = settings[tagID].copyOf()
    try:
      scratch.parseTagSetting(settingsToml.tableVal)
      settings[tagID] = scratch
    except ValueError:
      log "Invalid settings for tag " & tagIDstr & ": " & getCurrentExceptionMsg(), lvlError
