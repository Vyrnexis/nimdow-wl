import lists

export lists

iterator reverseNodes*[T](L: SomeLinkedList[T]): SomeLinkedNode[T] {.inline, closure.} =
  var it = L.tail
  while it != nil:
    yield it
    it = it.prev

proc swap*[T](a, b: var DoublyLinkedNode[T]) =
  let temp = a.value
  a.value = b.value
  b.value = temp

