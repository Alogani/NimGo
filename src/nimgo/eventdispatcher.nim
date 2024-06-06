import ./coroutines
import ./private/[timeoutwatcher]
import std/[deques, heapqueue]
import std/[os, selectors, nativesockets]
import std/[times, monotimes]

export Event, SocketHandle

#[
    {.push stackTrace:off.}
    # If stack trace is messed up, we would have to disable it for this file
    # There is also the possibility even there than using runEventLoop multiple times can mess it
    # One workaround could be to wrap the run the event loop indefinitly inside a suspendable coroutine
]#

type
    PollFd* = distinct int
        ## Reprensents a descriptor registered in the EventDispatcher: file handle, signal, timer, etc.
    
    OneShotCoroutine* = ref object
        ## Coroutine that can only be resumed once inside a dispatcher
        coro: Coroutine
        hasBeenResumed: bool
        refCountInsideSelector: int
        countInsideSelector: ptr int
        countInsideTimers: ptr int

    AsyncData = object
        readList: Deque[OneShotCoroutine] # Also stores all other event kind
        writeList: Deque[OneShotCoroutine]
        isTimer: bool

    WakeUpInfo = tuple[pollFd: PollFd, events: set[Event], byTimer: bool]

    CoroutineWithTimer = tuple[finishAt: MonoTime, coro: OneShotCoroutine]

    EvDispatcherObj = object
        running: bool
        lastWakeUpInfo: WakeUpInfo
        consumeEventFlag: bool # To avoid data race when multiple coro are waked up for same event
        selector: Selector[AsyncData]
        countInsideSelector: int
        pending: Deque[Coroutine]
        timers: HeapQueue[CoroutineWithTimer] # Thresold and not exact time
        countInsideTimers: int
    EvDispatcher* = ref EvDispatcherObj
        ## Cannot be shared or moved around threads


const InvalidFd* = PollFd(-1)
const SelectorBusySleepMs = 20
var ActiveDispatcher {.threadvar.}: EvDispatcher

proc newDispatcher*(): EvDispatcher
ActiveDispatcher = newDispatcher()


#[ *** OneShotCoroutineCoroutine API *** ]#

func `<`(a, b: CoroutineWithTimer): bool =
    a.finishAt < b.finishAt

proc toOneShot*(coro: Coroutine): OneShotCoroutine =
    OneShotCoroutine(coro: coro)

proc notifyRegistration(oneShotCoro: OneShotCoroutine, dispatcher: EvDispatcher, insideSelector: bool) =
    if oneShotCoro.hasBeenResumed:
        return
    if insideSelector:
        oneShotCoro.refCountInsideSelector.inc()
        if oneShotCoro.countInsideSelector == nil:
            dispatcher.countInsideSelector.inc()
            oneShotCoro.countInsideSelector = addr(dispatcher.countInsideSelector)
    else:
        if oneShotCoro.countInsideTimers == nil:
            dispatcher.countInsideTimers.inc()
            oneShotCoro.countInsideTimers = addr(dispatcher.countInsideTimers)

func hasBeenResumed*(oneShotCoro: OneShotCoroutine): bool =
    oneShotCoro.hasBeenResumed

proc consumeAndGet*(oneShotCoro: OneShotCoroutine): Coroutine =
    ## Eventual next coroutine will be ignored
    if oneShotCoro.hasBeenResumed:
        return nil
    result = oneShotCoro.coro
    if oneShotCoro.countInsideSelector != nil:
        oneShotCoro.countInsideSelector[].dec()
    if oneShotCoro.countInsideTimers != nil:
        oneShotCoro.countInsideTimers[].dec()
    oneShotCoro.coro = nil
    oneShotCoro.hasBeenResumed = true

proc removeFromSelector*(oneShotCoro: OneShotCoroutine, byTimer: bool) =
    ## Only consume when not referenced anymore inside dispatcher
    if oneShotCoro.hasBeenResumed:
        return
    if oneShotCoro.refCountInsideSelector == 1:
        if oneShotCoro.countInsideSelector == nil:
            discard consumeAndGet(oneShotCoro)
    else:
        oneShotCoro.refCountInsideSelector.dec()


#[ *** Coroutine API *** ]#

proc resumeImmediatly*(coro: Coroutine) =
    ## Will be put at the beggining of the timers queue
    ## Can starve the event loop
    ActiveDispatcher.timers.push(
        (low(MonoTime),
        coro.toOneShot())
    )

proc suspendUntilImmediatly*(coro: Coroutine = nil) =
    ## See `resumeImmediatly`
    let coroToUse = (
        if coro == nil:
            getCurrentCoroutineSafe()
        else:
            coro
    )
    resumeImmediatly(coroToUse)
    suspend(coroToUse)

proc resumeSoon*(coro: Coroutine) =
    ## Will be put at the beggining of the queue
    ## Will still be resumed after timers and event loop
    ActiveDispatcher.pending.addFirst coro

proc suspendUntilSoon*(coro: Coroutine) =
    ## See `resumeSoon`
    let coroToUse = (
        if coro == nil:
            getCurrentCoroutineSafe()
        else:
            coro
    )
    resumeSoon(coroToUse)
    suspend(coroToUse)

proc resumeLater*(coro: Coroutine) =
    ## Will be put at the end of the queue
    ActiveDispatcher.pending.addLast coro

proc suspendUntilLater*(coro: Coroutine = nil) =
    ## See `resumeLater`
    let coroToUse = (
        if coro == nil:
            getCurrentCoroutineSafe()
        else:
            coro
    )
    resumeLater(coroToUse)
    suspend(coroToUse)

proc resumeOnTimer*(coro: Coroutine, timeoutMs: int) =
    ## Equivalent to a sleep directly handled by the dispatcher
    let oneShotCoro = coro.toOneShot()
    oneShotCoro.notifyRegistration(ActiveDispatcher, false)
    ActiveDispatcher.timers.push(
        (getMonoTime() + initDuration(milliseconds = timeoutMs),
        oneShotCoro)
    )

proc resumeOnTimer*(oneShotCoro: OneShotCoroutine, timeoutMs: int) =
    ## Equivalent to a sleep directly handled by the dispatcher
    oneShotCoro.notifyRegistration(ActiveDispatcher, false)
    ActiveDispatcher.timers.push(
        (getMonoTime() + initDuration(milliseconds = timeoutMs),
        oneShotCoro)
    )

proc suspendUntilTimer*(coro: Coroutine, timeoutMs: int) =
    ## See `resumeOnTimer`
    let coroToUse = (
        if coro == nil:
            getCurrentCoroutineSafe()
        else:
            coro
    )
    resumeOnTimer(coroToUse, timeoutMs)
    suspend(coroToUse)

proc suspendUntilTimer*(timeoutMs: int) =
    suspendUntilTimer(nil, timeoutMs)

#[ *** Dispatcher API *** ]#

proc setCurrentThreadDispatcher*(dispatcher: EvDispatcher) =
    ## A dispatcher cannot be shared between threads
    ## But there could be one different dispatcher by threads
    ActiveDispatcher = dispatcher

proc getCurrentThreadDispatcher*(): EvDispatcher =
    return ActiveDispatcher

proc newDispatcher*(): EvDispatcher =
    return EvDispatcher(
        selector: newSelector[AsyncData]()
    )

proc isDispatcherEmpty*(dispatcher: EvDispatcher = ActiveDispatcher): bool =
    dispatcher.pending.len() == 0 and
        dispatcher.countInsideSelector == 0 and
        dispatcher.countInsideTimers == 0
    
proc processTimers(): TimeOutWatcher =
    ## Only as much timer as the queue length when entered to avoid starving the loop
    ## Returns the timeout until the next timer
    if ActiveDispatcher.countInsideTimers < 0:
        return initTimeoutWatcher(-1)
    ActiveDispatcher.lastWakeUpInfo = (InvalidFd, {}, true)
    var monotimeInit: bool
    var monoTimeNow: MonoTime
    for i in 0..2: # To avoid starving the loop, but handling maximum number of coroutines
        for i in 0 ..< ActiveDispatcher.timers.len():
            if ActiveDispatcher.timers[0].coro.hasBeenResumed:
                discard ActiveDispatcher.timers.pop()
                continue
            let nextFinishAt = ActiveDispatcher.timers[0].finishAt
            if not monotimeInit:
                # Costly operation, so we shall avoid doing it more than necessary
                monoTimeNow = getMonoTime()
                monotimeInit = true
            elif monoTimeNow <= nextFinishAt:
                monoTimeNow = getMonoTime()
            if monoTimeNow <= nextFinishAt:
                ActiveDispatcher.lastWakeUpInfo = (InvalidFd, {}, false)
                return initTimeoutWatcher((nextFinishAt - monoTimeNow).inMilliseconds())
            let coro = ActiveDispatcher.timers.pop().coro.consumeAndGet()
            resume(coro)
    if ActiveDispatcher.timers.len() == 0:
        ActiveDispatcher.lastWakeUpInfo = (InvalidFd, {}, false)
        return initTimeoutWatcher(-1)
    else:
        ActiveDispatcher.lastWakeUpInfo = (InvalidFd, {}, false)
        return timeoutWatcherFromFinishAt(ActiveDispatcher.timers[0].finishAt)

proc processSelector(timeout: var TimeOutWatcher) =
    ## Selector will return when timeout is expired or at least one coro has been resumed
    ## So if there are still coroutines to proceed, timeout should be 0
    if ActiveDispatcher.countInsideSelector == 0:
        return
    var hasResumed: bool
    while true:
        let remainingMs = timeout.getRemainingMs()
        let readyKeyList = ActiveDispatcher.selector.select(
            remainingMs,
        )
        if readyKeyList.len() == 0:
            break
        for readyKey in readyKeyList:
            ActiveDispatcher.selector.withData(readyKey.fd, asyncData) do:
                if Event.Write in readyKey.events:
                    ActiveDispatcher.lastWakeUpInfo = (
                        PollFd(readyKey.fd),
                        { Event.Write },
                        asyncData.isTimer,
                    )
                    ActiveDispatcher.consumeEventFlag = false
                    while asyncData.writeList.len() != 0:
                        let coro = asyncData.writeList.popFirst().consumeAndGet()
                        if coro == nil:
                            continue
                        hasResumed = true
                        resume(coro)
                        if ActiveDispatcher.consumeEventFlag:
                            break
                if readyKey.events.card() > 0 and {Event.Write} != readyKey.events:
                    ActiveDispatcher.lastWakeUpInfo = (
                        PollFd(readyKey.fd),
                        readykey.events - { Event.Write },
                        asyncData.isTimer,
                    )
                    ActiveDispatcher.consumeEventFlag = false
                    while asyncData.readList.len() != 0:
                        let coro = asyncData.readList.popFirst().consumeAndGet()
                        if coro == nil:
                            continue
                        hasResumed = true
                        resume(coro)
                        if ActiveDispatcher.consumeEventFlag:
                            break
        if hasResumed or remainingMs == 0:
            break
        sleep(min(SelectorBusySleepMs, remainingMs))
    ActiveDispatcher.lastWakeUpInfo = (InvalidFd, {}, false)

proc runOnce*(timeoutMs = -1) =
    ## Run the event loop. The poll phase is done only once
    ## For efficiency, timeout is only taken in account for the selector phase.
    ## Long calculations can starve the event loop. If that's the case, use resumeLast() regularly.
    var timeout = initTimeoutWatcher(timeoutMs)
    let nextTimerTimeout = processTimers()
    var selectorTimeout = (
        if ActiveDispatcher.pending.len() == 0:
            min(timeout, nextTimerTimeout)
        else:
            initTimeoutWatcher(0)
    )
    processSelector(selectorTimeout)
    discard processTimers()
    for i in 0..2: # To avoid starving the loop, but handling maximum number of coroutines
        for i in 0 ..< ActiveDispatcher.pending.len():
            let coro = ActiveDispatcher.pending.popFirst()
            resume(coro)

proc runEventLoop*(
        timeoutMs = -1,
        dispatcher = ActiveDispatcher,
    ) =
    ## The same event loop cannot be run twice.
    ## The event loop will stop when no coroutine is registered inside it
    ## Two kinds of deadlocks can happen when timeoutMs is not set:
    ## - if at least one coroutine waits for an event that never happens
    ## - if a coroutine never stops, or recursivly add coroutines
    if dispatcher.running:
        raise newException(ValueError, "Cannot run the same event loop twice")
    let oldDispatcher = ActiveDispatcher
    ActiveDispatcher = dispatcher
    dispatcher.running = true
    try:
        var timeout = initTimeoutWatcher(timeoutMs)
        while not timeout.expired():
            if dispatcher.isDispatcherEmpty():
                break
            runOnce(timeout.getRemainingMs())
    finally:
        dispatcher.running = false
        ActiveDispatcher = oldDispatcher

template withEventLoop*(body: untyped) =
    ## Ensures all coroutines registered will be executed, contrary to wait
    `body`
    runEventLoop()

template insideNewEventLoop*(dispatcher: EvDispatcher, body: untyped) =
    ## Temporarly replace the current event loop.
    ## This means, you can't use any AsyncObjects defined before like `goStdin, `goStdout`.
    ## But we can register them in the new dispatcher.
    ## And no coroutines defined before will be executed
    let oldDispatcher = ActiveDispatcher
    ActiveDispatcher = dispatcher
    `body`
    runEventLoop()
    ActiveDispatcher = oldDispatcher

template insideNewEventLoop*(body: untyped) =
    ## Temporarly replace the current event loop.
    ## This means, you can't use any AsyncObjects defined before like `goStdin, `goStdout`.
    ## But we can register them in the new dispatcher.
    ## And no coroutines defined before will be executed
    let oldDispatcher = ActiveDispatcher
    ActiveDispatcher = newDispatcher()
    `body`
    runEventLoop()
    ActiveDispatcher = oldDispatcher

proc running*(dispatcher = ActiveDispatcher): bool =
    dispatcher.running


#[ *** Poll fd API *** ]#

func `==`*(a, b: PollFd): bool =
    int(a) == int(b)

func isInvalid*(pollFd: PollFd): bool =
    pollFd == InvalidFd

proc consumeCurrentEvent*() =
    ## Will prevent other coroutines to resume until the next loop
    ActiveDispatcher.consumeEventFlag = true

proc registerEvent*(
    ev: SelectEvent,
    coros: seq[OneShotCoroutine] = @[],
) =
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    ActiveDispatcher.selector.registerEvent(ev, AsyncData(readList: toDeque(coros)))

proc registerHandle*(
    fd: int | SocketHandle,
    events: set[Event],
): PollFd =
    result = PollFd(fd)
    ## std/selectors will raise here when trying to register twice
    ActiveDispatcher.selector.registerHandle(fd, events, AsyncData())

proc registerProcess*(
    pid: int,
    coros: seq[OneShotCoroutine] = @[],
): PollFd =
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    result = PollFd(ActiveDispatcher.selector.registerProcess(pid, AsyncData(
            readList: toDeque(coros),
        )))

proc registerSignal*(
    signal: int,
    coros: seq[OneShotCoroutine] = @[],
): PollFd =
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    result = PollFd(ActiveDispatcher.selector.registerSignal(signal, AsyncData(
        readList: toDeque(coros),
    )))

proc registerTimer*(
    timeoutMs: int,
    coros: seq[OneShotCoroutine] = @[],
    oneshot: bool = true,
): PollFd =
    ## Timer is registered inside the poll, not inside the event loop.
    ## Use another function to sleep inside the event loop (more reactive, less overhead for short sleep)
    ## Coroutines will only be resumed once, even if timer is not oneshot. You need to associate them to the fd each time for a periodic action
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    result = PollFd(ActiveDispatcher.selector.registerTimer(timeoutMs, oneshot, AsyncData(
        readList: toDeque(coros),
        isTimer: true,
    )))

proc unregister*(fd: PollFd) =
    ## It will also consume all coroutines registered inside it
    when not defined(release):
        if not ActiveDispatcher.selector.contains(fd.int):
            raise newException(ValueError, "Can't unregister file descriptor " & $fd.int & " twice")
    var asyncData = ActiveDispatcher.selector.getData(fd.int)
    ActiveDispatcher.selector.unregister(fd.int)
    for coro in asyncData.readList:
        coro.removeFromSelector(false)
    for coro in asyncData.writeList:
        coro.removeFromSelector(false)

proc addInsideSelector*(fd: PollFd, oneShotCoro: OneShotCoroutine, event: Event) =
    ## Will not update the type event listening
    oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    if event == Event.Write:
        ActiveDispatcher.selector.getData(fd.int).writeList.addLast(oneShotCoro)
    else:
        ActiveDispatcher.selector.getData(fd.int).readList.addLast(oneShotCoro)

proc addInsideSelector*(fd: PollFd, coros: seq[OneShotCoroutine], event: Event) =
    ## Will not update the type event listening
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    when not defined(release):
        if not ActiveDispatcher.selector.contains(fd.int):
            raise newException(ValueError, "The file handle " & $fd.int & " is not registered with the event selector.")
    if event == Event.Write:
        for coro in coros:
            ActiveDispatcher.selector.getData(fd.int).writeList.addLast(coro)
    else:
        for coro in coros:
            ActiveDispatcher.selector.getData(fd.int).readList.addLast(coro)

proc updatePollFd*(fd: PollFd, events: set[Event]) =
    ## std/selector raise here if fd is not registered
    ActiveDispatcher.selector.updateHandle(fd.int, events)

proc sleepAsync*(timeoutMs: int) =
    if timeoutMs == 0:
        suspendUntilLater()
    else:
        suspendUntilTimer(timeoutMs)

proc pollOnce*() =
    ## Works both inside and outside dispatcher
    let coro = getCurrentCoroutine()
    if coro == nil:
        runOnce()
    else:
        suspendUntilLater(coro)

proc wasWakeUpByTimer*(): bool =
    ## Only works inside a coroutine resumed by dispatcher
    ActiveDispatcher.lastWakeUpInfo.byTimer

proc suspendUntilAny*(readFd: seq[PollFd], writefd: seq[PollFd], timeoutMs = -1): WakeUpInfo =
    let coro = getCurrentCoroutineSafe()
    let oneShotCoro = toOneShot(coro)
    for fd in readFd:
        addInsideSelector(fd, oneShotCoro, Event.Read)
    for fd in writefd:
        addInsideSelector(fd, oneShotCoro, Event.Write)
    if timeoutMs == -1:
        resumeOnTimer(oneShotCoro, timeoutMs)
    suspend(coro)
    return ActiveDispatcher.lastWakeUpInfo

proc suspendUntilRead*(fd: PollFd, timeoutMs = -1, consumeEvent = true): bool =
    ## See also `consumeCurrentEvent` to avoid a data race if multiple coros are registered for same fd
    ## If PollFd is not a file, by definition only the coros in the readList will be resumed
    ## It will not try to update the kind of event waited inside the selector. Waiting for unregistered event will deadlock
    let coro = getCurrentCoroutineSafe()
    let oneShotCoro = toOneShot(coro)
    addInsideSelector(fd, oneShotCoro, Event.Read)
    if timeoutMs != -1:
        resumeOnTimer(oneShotCoro, timeoutMs)
    suspend(coro)
    if ActiveDispatcher.lastWakeUpInfo.byTimer:
        return false
    if consumeEvent:
        consumeCurrentEvent()
    return true

proc suspendUntilWrite*(fd: PollFd, timeoutMs = -1, consumeEvent = true): bool =
    ## If PollFd is not a file, by definition only the coros in the readList will be resumed
    ## It will not try to update the kind of event waited inside the selector. Waiting for unregistered event will deadlock
    ## consumeEvent permits to avoid a data race if multiple coros are registered for same fd
    let coro = getCurrentCoroutineSafe()
    let oneShotCoro = toOneShot(coro)
    addInsideSelector(fd, oneShotCoro, Event.Write)
    if timeoutMs != -1:
        resumeOnTimer(oneShotCoro, timeoutMs)
    suspend(coro)
    if ActiveDispatcher.lastWakeUpInfo.byTimer:
        return false
    if consumeEvent:
        consumeCurrentEvent()
    return true
