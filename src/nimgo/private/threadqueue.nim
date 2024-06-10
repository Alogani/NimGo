import ./[safecontainer, smartptrs]


## Lock free (thread safe) queue implementation using linked list
## Constant complexity with minimal overhead even if push/pop are not balanced

type
    Node[T] = object
        val: SafeContainer[T]
        next: Atomic[ptr Node[T]]

    ThreadQueueObj[T] = object
        head: Atomic[ptr Node[T]]
        tail: Atomic[ptr Node[T]]

    ThreadQueue*[T] = SharedPtr[ThreadQueueObj[T]]


proc `=destroy`*[T](q: ThreadQueueObj[T]) {.nodestroy.} =
    let qAddr = addr q
    var currentNode = qAddr[].head.load(moRelaxed)
    while currentNode != nil:
        let nextNode = currentNode.next.load(moRelaxed)
        destroy(currentNode.val)
        deallocShared(currentNode)
        currentNode = nextNode

proc newThreadQueue*[T](): ThreadQueue[T] =
    let node = allocSharedAndSet(Node[T]())
    let atomicNode = newAtomic(node)
    return newSharedPtr(ThreadQueueObj[T](
        head: atomicNode,
        tail: atomicNode
    ))

proc addLast*[T](q: ThreadQueue[T], val: sink T) =
    let newNode = allocSharedAndSet(Node[T](
        val: pushIntoContainer(val),
        next: newAtomic[ptr Node[T]](nil),
    ))
    let prevTail = q[].tail.exchange(newNode)
    prevTail[].next.store(newNode)

proc popFirst*[T](q: ThreadQueue[T], outVal: out T): bool =
    var oldHead = q[].head.load(moAcquire)
    let newHead = oldHead[].next.load(moAcquire)
    if newHead == nil:
        return false
    if q[].head.compareExchange(oldHead, newHead):
        outVal = newHead[].val.toVal()
        deallocShared(oldHead)
        return true

proc empty*[T](q: ThreadQueue[T]): bool =
    ## The atomicity cannot be guaranted
    return q[].head.load(moAcquire) == q[].tail.load(moAcquire)