import
  nimtest,
  wm/tags,
  config/tagsettings,
  parsetoml

describe "Tag settings":

  it "parses a valid tags table":
    let testToml: string = """
    [1]
    displayString = "one"
    numMasterWindows = 2
    """

    var settings = createDefaultTagSettings()
    let toml = parseString(testToml)
    populateTagSettings(settings, toml.tableVal)

    assert settings[1].displayString == "one"
    assert settings[1].numMasterWindows == 2

    for i in 2 .. tagCount:
      assert settings[i].displayString == $i
      assert settings[i].numMasterWindows == 1

  it "parses a valid [all] tags table":
    let testToml: string = """
    [all]
    displayString = "[]"
    numMasterWindows = 2

    [7]
    displayString = "Seven"
    numMasterWindows = 3
    """

    var settings = createDefaultTagSettings()
    let toml = parseString(testToml)
    populateTagSettings(settings, toml.tableVal)

    for i in 1 .. tagCount:
      if i == 7:
        assert settings[i].displayString == "Seven"
        assert settings[i].numMasterWindows == 3
      else:
        assert settings[i].displayString == "[]"
        assert settings[i].numMasterWindows == 2


describe "Tag settings validation":

  it "skips tag ids outside the valid range":
    let toml = parseString """
    [0]
    displayString = "zero"

    [10]
    displayString = "ten"

    [x]
    displayString = "bad"

    [3]
    displayString = "three"
    """
    var settings = createDefaultTagSettings()
    populateTagSettings(settings, toml.tableVal)
    assert settings.len == tagCount
    assert settings[3].displayString == "three"
    assert settings[1].displayString == "1"

  it "keeps a tag untouched when one of its values is invalid":
    let toml = parseString """
    [2]
    displayString = "two"
    numMasterWindows = "many"

    [4]
    numMasterWindows = 0

    [5]
    numMasterWindows = 3
    """
    var settings = createDefaultTagSettings()
    populateTagSettings(settings, toml.tableVal)
    assert settings[2].displayString == "2"
    assert settings[4].numMasterWindows == 1
    assert settings[5].numMasterWindows == 3
