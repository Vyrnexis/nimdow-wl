import
  nimtest,
  sets,
  config/configloader,
  wm/client,
  wm/monitor,
  wm/tags

proc newTestMonitor(): Monitor =
  newMonitor(1, nil, (0, 0, 1000.uint, 600.uint), newConfig())

describe "Monitor tags":

  it "keeps the last viewed tag when toggling it off":
    let m = newTestMonitor()
    m.toggleTags(TagID(1))
    assert m.selectedTags.len == 1
    assert 1 in m.selectedTags

  it "toggles tags while at least one stays viewed":
    let m = newTestMonitor()
    m.toggleTags(TagID(2))
    assert m.selectedTags.len == 2
    m.toggleTags(TagID(1))
    assert m.selectedTags.len == 1
    assert 2 in m.selectedTags

  it "adds a client to the viewed tags":
    let m = newTestMonitor()
    m.toggleTags(TagID(2))
    let c = newClient(nil)
    m.addClient(c)
    assert c.tagIDs == {TagID(1), 2}

  it "adds a client without a crash when no tag is viewed":
    let m = newTestMonitor()
    m.selectedTags.clear()
    let c = newClient(nil)
    m.addClient(c)
    assert c.tagIDs.len == 1
