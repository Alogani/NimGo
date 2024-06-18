import std/[os, posix, selectors]
import std/[atomics, cpuinfo, locks]
import std/deques


const IoPoolSize* {.intdefine.} = 0

proc getMaxIoThreads(): int =
  if IoPoolSize > 0:
    return IoPoolSize
  else:
    return countProcessors()


type
  IoOperation* = object
    fd: AsyncFd
    readOnGoing: Atomic[bool]
    writeOnGoing: Atomic[bool]
    event: Event
    userData: pointer
    buffer: pointer
    bytesRequested: int
    bytesTransfered: int
    done: Atomic[bool]

  AsyncData = object
    lock: Lock # Important to avoid data race on updates on listening events
    eventsRegistered: set[Event]
    readList: Deque[ptr IoOperation]
    writeList: Deque[ptr IoOperation]

  AsyncFd* = FileHandle

  IoCompletionPoolObj = object
    selfThread: Thread[void]
    selector: Selector[AsyncData]
    workerCount: Atomic[int]
    completed: Channel[ptr IoOperation]
    distributed: Channel[ptr IoOperation]
    stopFlag: bool
  IoCompletionPool* = ptr IoCompletionPoolObj


proc createIoCompletionPool(): IoCompletionPool
let GlobalIoCompletionPool* = createIoCompletionPool()


proc getTransferedBytesCount*(ioOperation: IoOperation): int =
  return ioOperation.bytesTransfered

proc getUserData*(ioOperation: IoOperation): pointer =
  return ioOperation.userData

#[ *** IO Pool API *** ]#

proc processIo(ioOpPtr: ptr IoOperation, event: Event) =
  var expected = false
  if compareExchange(ioOpPtr[].done, expected, true):
    if event == Event.Read:
      let transfered = read(ioOpPtr[].fd, ioOpPtr[].buffer, ioOpPtr[].bytesRequested)
      ioOpPtr[].bytesTransfered = transfered
      if transfered == -1:
        raiseOSError(osLastError())
    else:
      let transfered = write(ioOpPtr[].fd, ioOpPtr[].buffer, ioOpPtr[].bytesRequested)
      ioOpPtr[].bytesTransfered = transfered
      if transfered == -1:
        raiseOSError(osLastError())
  GlobalIoCompletionPool.completed.send(ioOpPtr)

proc processDistributedQueue(masterWorker: bool): bool =
  #[
    Core of thread management obeing simple rules:
      - masterWorker only try once and never loop (to not starve other stuff). It returns true if it has completed an I/O operation
      - childWorker loop forever, but if distributed chan is empty, sleep several short times and then stop
    This allows shrinking the thread pool without complex algorithm, but maintining acceptable reactivity and resource usage
    Data-racing on IO operations:
      - similar operation on same fd aren't done in IoOperation will be renqueued
      - if distributed channel contains no other operations, it is considered empty
  ]#
  var lastOperationPtr: ptr IoOperation
  var lastOperationKind: Event
  var repCount = 0
  const maxRepCount = 5
  const emptySleepMs = 10
  while repCount < maxRepCount:
    let tried = GlobalIoCompletionPool.distributed.tryRecv()
    if not tried.dataAvailable:
      if masterWorker:
        return false
      else:
        repCount.inc()
        sleep(emptySleepMs)
        continue
    let ioOpPtr = tried.msg
    var expected = false
    if ioOpPtr[].event == Event.Read:
      if not ioOpPtr[].readOngoing.compareExchange(expected, true):
        GlobalIoCompletionPool.distributed.send(ioOpPtr)
        if masterWorker:
          return false
        if lastOperationPtr == ioOpPtr and lastOperationKind == Event.Read:
          repCount.inc()
        lastOperationPtr = ioOpPtr
        lastOperationKind = Event.Read
        sleep(emptySleepMs)
        continue
      processIo(ioOpPtr, Event.Read)
      ioOpPtr[].readOngoing.store(false)
    else:
      if not ioOpPtr[].writeOngoing.compareExchange(expected, true):
        GlobalIoCompletionPool.distributed.send(ioOpPtr)
        if masterWorker:
          return false
        if lastOperationPtr == ioOpPtr and lastOperationKind == Event.Write:
          repCount.inc()
        lastOperationPtr = ioOpPtr
        lastOperationKind = Event.Write
        sleep(emptySleepMs)
        continue
      processIo(ioOpPtr, Event.Write)
      ioOpPtr[].writeOngoing.store(false)
    if masterWorker:
      return true
    repCount = 0
    lastOperationPtr = nil
  
proc workerIoLoop*() {.thread.} =
  GlobalIoCompletionPool.workerCount.atomicInc()
  discard processDistributedQueue(false)
  GlobalIoCompletionPool.workerCount.atomicDec()

proc masterIoLoop*() {.thread.} =
  const maxPendingBeforeSpawn = 10
  const minimumWorkerCountBeforeDedicated = 4
  const emptySleepMs = 50
  var allThreads: seq[Thread[void]] # risk of nil deference ?
  let maxThreads = getMaxIoThreads() - 1
  while not GlobalIoCompletionPool.stopFlag:
    ## A more coherent sleep time is needed and to estimate number of pending operations if no other threads (peek)
    var readyKeyList = GlobalIoCompletionPool.selector.select(
      if hasPendingWork:
        0
      else:
        emptySleepMs
    )
    var currentWorkerCount = GlobalIoCompletionPool.workerCount.load()
    if readyKeyList.len() > maxPendingBeforeSpawn and currentWorkerCount < maxThreads:
      for i in 0..high(allThreads):
        if not allThreads[i].running():
          allThreads.del(i)
      var newThread: Thread[void]
      createThread(newThread, workerIoLoop)
      allThreads.add newThread
      currentWorkerCount.inc()
    for key in readyKeyList:
      withData(GlobalIoCompletionPool.selector, key.fd, asyncData):
        acquire(asyncData.lock)
        if key.events.card() > 0 and { Event.Write } != key.events:
          if asyncData.readList.len() == 0:
            asyncData.eventsRegistered = asyncData.eventsRegistered * { Event.Write }
            updateHandle(GlobalIoCompletionPool.selector, key.fd, asyncData.eventsRegistered)
          else:
            GlobalIoCompletionPool.distributed.send(asyncData.readList.popFirst())
        if Event.Write in key.events:
          if asyncData.writeList.len() == 0:
            asyncData.eventsRegistered.excl(Event.Write)
            updateHandle(GlobalIoCompletionPool.selector, key.fd, asyncData.eventsRegistered)
          else:
            GlobalIoCompletionPool.distributed.send(asyncData.writeList.popFirst())
        release(asyncData.lock)
    if readyKeyList.len() == 0:
      var timeout = initTimeoutWatcher(emptySleepMs)
      if not processDistributedQueue(true):
        sleep(emptySleepMs)
      else:
        while not timeout.expired():
          if not processDistributedQueue(true):
            break
    elif currentWorkerCount < minimumWorkerCountBeforeDedicated:
      for i in 0..(high(readyKeyList) div (currentWorkerCount + 1)):
        if not processDistributedQueue(true):
          break
  close(GlobalIoCompletionPool.distributed)
  close(GlobalIoCompletionPool.completed)
  joinThreads(allThreads)


proc createIoCompletionPool(): IoCompletionPool =
  result = cast[IoCompletionPool](allocShared0(sizeof IoCompletionPoolObj))
  result[].selector = newSelector[AsyncData]()
  open(result[].completed)
  open(result[].distributed)
  createThread(result[].selfThread, masterIoLoop)
  return result


proc stopAndCloseIoLoop*() =
  GlobalIoCompletionPool[].stopFlag = true
  joinThread(GlobalIoCompletionPool[].selfThread)
  deallocShared(GlobalIoCompletionPool)


proc getQueuedCompletedIo*(): ptr IoOperation =
  # No waiting, return nil if empty
  var tried = GlobalIoCompletionPool.completed.tryRecv()
  if not tried.dataAvailable:
    return nil
  else:
    return tried.msg



#[ *** IO API *** ]#

proc registerHandle*(fd: AsyncFd) =
  ## Note for windows, file should have been opened with FILE_FLAG_OVERLAPPED
  ## Note for unix, not event is specified to be waited
  # Normally, not thread unsafe
  var lock: Lock
  initLock(lock)
  registerHandle(GlobalIoCompletionPool.selector, fd, {}, AsyncData(
    lock: lock,
    eventsRegistered: {}
  ))

proc unregister*(fd: AsyncFd) =
  withData(GlobalIoCompletionPool.selector, fd.int, asyncdata):
    unregister(GlobalIoCompletionPool.selector, fd)
    asyncdata.lock.acquire()
    asyncdata.lock.release()
    deinitLock(asyncdata.lock)

template addReadEventWithLock(fd: AsyncFd, body: untyped): untyped =
  ## Automatically removed
  withData(GlobalIoCompletionPool.selector, fd.int, asyncdata):
    acquire(asyncdata.lock)
    asyncdata.eventsRegistered.incl(Event.Read)
    updateHandle(GlobalIoCompletionPool.selector, fd, asyncdata.eventsRegistered)
    `body`
    release(asyncdata.lock)

template addWriteEventWithLock(fd: AsyncFd, body: untyped): untyped =
  ## Automatically removed
  withData(GlobalIoCompletionPool.selector, fd.int, asyncdata):
    acquire(asyncdata.lock)
    asyncdata.eventsRegistered.incl(Event.Write)
    updateHandle(GlobalIoCompletionPool.selector, fd, asyncdata.eventsRegistered)
    `body`
    release(asyncdata.lock)


proc readFileAsync*(fd: AsyncFd, buffer: pointer, size: int, ioOperation: var IOOperation) =
  ioOperation.fd = fd
  ioOperation.buffer = buffer
  ioOperation.bytesRequested = size
  when not defined(danger):
    if not GlobalIoCompletionPool.selector.contains(fd.int):
      raise newException(ValueError, "File handle " & $fd & " is not registered")
  addReadEventWithLock(fd):
    GlobalIoCompletionPool.selector.withData(fd, asyncData) do:
      asyncData.readList.addLast(addr ioOperation)

#[
Example
var fd = AsyncFd(0)
registerHandle(fd)
var buffer = newString(1024)
var ioOperation: IOOperation
readFileAsync(fd, addr(buffer[0]), 10, ioOperation)
while true:
  var newIoOperation = getQueuedCompletedIo()
  echo newIoOperation == nil
  if newIoOperation != nil:
    break
echo "rawbuf=", buffer
setLen(buffer, ioOperation.getTransferedBytesCount())
echo "buf=", buffer
]#
