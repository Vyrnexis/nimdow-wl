import
  taginfo,
  layouts/masterstacklayout

export taginfo, masterstacklayout

type
  Tag* = ref object
    id*: TagID
    layout*: MasterStackLayout

proc newTag*(id: TagID, layout: MasterStackLayout): Tag =
  Tag(
    id: id,
    layout: layout
  )

