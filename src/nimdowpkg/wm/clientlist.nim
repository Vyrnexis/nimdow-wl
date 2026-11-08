import
  lists,
  listutils,
  sets,
  sequtils,
  sugar

import
  client,
  tags,
  masterstack

export tags, masterstack, client, lists, sets

type
  Tag* = ref object
    id*: TagID
    layout*: MasterStackLayout

  ClientNode* = DoublyLinkedNode[Client]

  TaggedClients* = ref object
    clients*: DoublyLinkedList[Client]
    # TODO: Needs a better name.
    # This is the order of clients based on selection order, oldest to newest.
    clientSelection*: seq[Client]

    tags*: seq[Tag]
    selectedTags*: OrderedSet[TagID]

proc newTag*(id: TagID, layout: MasterStackLayout): Tag =
  Tag(
    id: id,
    layout: layout
  )

proc newTaggedClients*(): TaggedClients = TaggedClients()

iterator currClientsIter*(this: TaggedClients): ClientNode {.inline, closure.} =
  ## Iterates over clients in stack order.
  for node in this.clients.nodes:
    if node.value.tagIDs.anyIt(this.selectedTags.contains(it)):
      yield node

iterator currClientsReverseIter*(this: TaggedClients): ClientNode {.inline, closure.} =
  ## Iterates over clients in reverse stack order.
  for node in this.clients.reverseNodes:
    if node.value.tagIDs.anyIt(this.selectedTags.contains(it)):
      yield node

proc findNodeByWindow*(this: TaggedClients, window: Window): ClientNode =
  ## Finds a client based on its window property.
  for node in this.clients.nodes:
    if node.value.window == window:
      return node

proc findLastLayoutNode*( this: TaggedClients): ClientNode =
  for n in this.currClientsReverseIter:
    if not n.value.isFloating:
      return n

proc findNextCurrClient*(
  this: TaggedClients,
  startClient: Client,
  reversed: bool = false,
  accept: proc(client: Client): bool = (client: Client) => true
): ClientNode =
  ## The next (or previous, if `reversed`) client on the selected tags after
  ## `startClient` that `accept`s, wrapping around. Nil if there is none.
  if startClient == nil:
    return nil

  template forEachClientNode(node, body: untyped) =
    if reversed:
      for node in this.currClientsReverseIter:
        body
    else:
      for node in this.currClientsIter:
        body

  var startClientFound = false
  forEachClientNode(node):
    if startClientFound:
      if accept(node.value):
        return node
    elif startClient == node.value:
      startClientFound = true

  # Client was not in the list!
  if not startClientFound:
    return nil

  # Wrap around, up to the start client.
  forEachClientNode(node):
    if node.value == startClient:
      return nil
    if accept(node.value):
      return node

iterator currClientsSelectionNewToOldIter*(this: TaggedClients): Client {.inline, closure.} =
  ## Iterates over clients in order of selection,
  ## from most recent to least recent.
  for i in countdown(this.clientSelection.high, this.clientSelection.low):
    let client = this.clientSelection[i]
    if client.tagIDs.anyIt(this.selectedTags.contains(it)):
      yield client

proc findCurrentClients*(this: TaggedClients): seq[Client] =
  for node in this.currClientsIter:
    result.add(node.value)

proc currClientNode*(this: TaggedClients): ClientNode =
  ## Gets the most recently selected client (as a node) in the list
  ## of clients that are available in the selectedTags.
  var currClient: Client
  for client in this.currClientsSelectionNewToOldIter:
      currClient = client
      break

  if currClient == nil:
    return nil

  return this.findNodeByWindow(currClient.window)

proc currClient*(this: TaggedClients): Client =
  ## Gets the most recently selected client in the list
  ## of clients that are available in the selectedTags.
  for client in this.currClientsSelectionNewToOldIter:
    return client

template withSomeCurrClient*(this: TaggedClients, client, body: untyped) =
  ## Executes `body` if `this.currClient != nil`
  let client = this.currClient
  if client != nil:
    body

proc removeByWindow*(this: TaggedClients, window: Window): bool =
  # Remove the client from the list.
  for node in this.clients.nodes:
    if node.value.window == window:
      node.value.monitorID = 0
      this.clients.remove(node)
      result = true
      break

  # Remove the client from the selection list.
  for i, client in this.clientSelection:
    if client.window == window:
      this.clientSelection.delete(i)
      break

proc selectClient*(this: TaggedClients, window: Window) =
  ## Sets the client as the most recently selected,
  ## found by its window.
  var foundClient: Client
  for i, client in this.clientSelection:
    if client.window == window:
      foundClient = client
      this.clientSelection.delete(i)
      break

  if foundClient != nil:
    this.clientSelection.add(foundClient)

proc findFirstSelectedTag*(this: TaggedClients): Tag =
  for id in this.selectedTags.items:
    return this.tags[id - 1]
