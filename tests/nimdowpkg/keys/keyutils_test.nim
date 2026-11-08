import
  nimtest,
  tables,
  keys/keyutils

describe "Key names":

  it "maps upper and lower case letters to the same keysym":
    assert toKeysym("R") == toKeysym("r")
    assert toKeysym("r") != NoSymbol

  it "accepts key names in any case":
    assert toKeysym("return") == toKeysym("Return")
    assert toKeysym("Return") != NoSymbol

  it "rejects unknown names":
    assert toKeysym("NotAKey") == NoSymbol
    assert toKeysym("") == NoSymbol

  it "has the modifier names in lower case":
    assert ModifierTable.hasKey("super")
    assert not ModifierTable.hasKey("Super")
