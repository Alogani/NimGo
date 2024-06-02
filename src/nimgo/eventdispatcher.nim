#[
    Event loop implementation close inspired by nodejs/libuv (for more details: https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick).
    With the main difference of resuming coroutines instead of running callbacks (I'll use "worker" term to design the code answering an event)
    As so, it shares the main advantages and drawbacks. Mainly :
        - If multiple workers listen to the same event, they will be both runned, even if the event is consumed (could result in a blocking operation)
        - Worker execution pauses the event loop, and will delay the execution of the event loop, and by extension other workers
          This could have a negative impact on the overall performance and responsivness
    But here are principal differences with the nodejs implementation:
        - The poll phase will not wait indefinitly for I/O events if no timers are registers (unless NimGoNoThread is set)
          It will instead wait for a maximum of time defined by `EvDispatcherTimeOut` constant (can be tweaked with `-d:EvDispatcherTimeOut:Number`)
          This will allow the loop to be rerun to take into account workers and new events.
        - If the event loop and poll queue is empty, runOnce will immediatly return
    If you notice other differences with libuv, please let me now (I will either document it or implement it)

    Design has not been oriented for strong cancellation support, as it would add some overhead and is expected to be a corner case.
    However, workarounds should be easy by dissociating the waiting of a resource availability from its usage, or by using goasync/wait
]#

import ./coroutines
import ./private/[timeoutwatcher]
import std/[deques, heapqueue]
import std/[os, selectors, nativesockets]
import std/[times, monotimes]

export Event

const EvDispatcherTimeoutMs {.intdefine.} = 20 # We don't block on poll phase if new coros were registered
const SleepMsIfInactive = 5 # to avoid busy waiting. When selector is not empty, but events triggered with no associated coroutines
const CoroLimitByPhase = 50 # To avoid starving the coros inside the poll

type
    OneShotCoroutine* = ref object
        ## Coroutine that can only be resumed once inside a dispatcher
        coro: Coroutine
        activeCorosInsideSelector: ptr int
        refCountInsideSelector: int
        activeCorosOutsideSelector: ptr int
        cancelled: bool
        cancelledByTimer: bool

    AsyncData = object
        readList: seq[OneShotCoroutine] # Also stores all other event kind
        writeList: seq[OneShotCoroutine]
        unregisterWhenTriggered: bool
        isTimer: bool

    PollFd* = distinct int
        ## Reprensents a descriptor registered in the EventDispatcher: file handle, signal, timer, etc.

    CoroutineWithTimer = tuple[finishAt: MonoTime, coro: OneShotCoroutine]

    EvDispatcherObj = object
        running: bool
        ## Phases
        activeCorosInsideSelector: int
        activeCorosOutsideSelector: int
        consumeEvent: bool ## To avoid data race when multiple coro are waked up for same event !!!
        selector: Selector[AsyncData]
        onNextTickCoros: Deque[Coroutine]
        timers: HeapQueue[CoroutineWithTimer] # Thresold and not exact time
        pendingCoros: Deque[Coroutine]
        checkCoros: Deque[Coroutine]
        closeCoros: Deque[Coroutine]
    EvDispatcher* = ref EvDispatcherObj
        ## Cannot be shared or moved around threads

var ActiveDispatcher {.threadvar.}: EvDispatcher

proc newDispatcher*(): EvDispatcher
ActiveDispatcher = newDispatcher()

#[ *** OneShotCoroutineCoroutine API *** ]#

proc `<`(a, b: CoroutineWithTimer): bool =
    a.finishAt < b.finishAt

proc toOneShot*(coro: Coroutine): OneShotCoroutine =
    OneShotCoroutine(
        coro: coro,
    )

proc notifyRegistration(oneShotCoro: OneShotCoroutine, dispatcher: EvDispatcher, insideSelector: bool) =
    if oneShotCoro.cancelled:
        return
    if insideSelector:
        oneShotCoro.refCountInsideSelector.inc()
        if oneShotCoro.activeCorosInsideSelector != nil:
            return
        dispatcher.activeCorosInsideSelector.inc()
        oneShotCoro.activeCorosInsideSelector = addr(dispatcher.activeCorosInsideSelector)
    else:
        if oneShotCoro.activeCorosOutsideSelector != nil:
            return
        dispatcher.activeCorosOutsideSelector.inc()
        oneShotCoro.activeCorosOutsideSelector = addr(dispatcher.activeCorosOutsideSelector)


proc cancelled*(oneShotCoro: OneShotCoroutine): bool =
    oneShotCoro.cancelled

proc consumeAndGet*(oneShotCoro: OneShotCoroutine, byTimer: bool): Coroutine =
    ## Eventual next coroutine will be ignored
    if oneShotCoro.cancelled:
        return nil
    result = oneShotCoro.coro
    if oneShotCoro.activeCorosInsideSelector != nil:
        oneShotCoro.activeCorosInsideSelector[].dec()
    if oneShotCoro.activeCorosOutsideSelector != nil:
        oneShotCoro.activeCorosOutsideSelector[].dec()
    oneShotCoro.coro = nil
    oneShotCoro.cancelled = true
    if byTimer:
        oneShotCoro.cancelledByTimer = true

proc removeFromSelector*(oneShotCoro: OneShotCoroutine, byTimer: bool) =
    ## Only consume when not referenced anymore inside dispatcher
    if oneShotCoro.cancelled:
        return
    if oneShotCoro.refCountInsideSelector == 1:
        if oneShotCoro.activeCorosOutsideSelector == nil:
            discard consumeAndGet(oneShotCoro, byTimer)
    else:
        oneShotCoro.refCountInsideSelector.dec()

#[ *** Coroutine API *** ]#

proc resumeSoon*(coro: Coroutine) =
    ## Will register in the "pending phase"
    ActiveDispatcher.pendingCoros.addLast coro

proc resumeOnTimer*(oneShotCoro: OneShotCoroutine, timeoutMs: int) =
    ## Equivalent to a sleep directly handled by the dispatcher
    ## Returns an optional consummable object
    oneShotCoro.notifyRegistration(ActiveDispatcher, false)
    ActiveDispatcher.timers.push(
        (getMonoTime() + initDuration(milliseconds = timeoutMs),
        oneShotCoro)
    )

proc resumeOnNextTick*(coro: Coroutine) =
    ActiveDispatcher.onNextTickCoros.addLast coro

proc resumeOnCheckPhase*(coro: Coroutine) =
    ActiveDispatcher.checkCoros.addLast coro

proc resumeOnClosePhase*(coro: Coroutine) =
    ActiveDispatcher.closeCoros.addLast coro


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
    dispatcher[].activeCorosInsideSelector == 0 and
        dispatcher[].activeCorosOutsideSelector == 0 and
        dispatcher[].onNextTickCoros.len() == 0 and
        dispatcher[].pendingCoros.len() == 0 and
        dispatcher[].checkCoros.len() == 0 and
        dispatcher[].closeCoros.len() == 0

proc processNextTickCoros(timeout: TimeOutWatcher) {.inline.} =
    while not (ActiveDispatcher.onNextTickCoros.len() == 0 or timeout.expired):
        ActiveDispatcher.onNextTickCoros.popFirst().resume()

proc processTimers(coroLimitForTimer: var int, timeout: TimeOutWatcher) =
    while coroLimitForTimer < CoroLimitByPhase or ActiveDispatcher.activeCorosInsideSelector == 0:
        if timeout.expired():
            break
        if ActiveDispatcher.timers.len() == 0:
            ## Blazingly faster than getMonoTime
            break
        var monoTimeNow = getMonoTime()
        var hasResumed = false
        if ActiveDispatcher.timers.len() != 0:
            if monoTimeNow > ActiveDispatcher.timers[0].finishAt:
                let coro = ActiveDispatcher.timers.pop().coro.consumeAndGet(true)
                if coro != nil:
                    hasResumed = true
                    resume(coro)
                processNextTickCoros(timeout)
                coroLimitForTimer += 1
        if not hasResumed:
            break

proc runOnce*(timeoutMs = -1) =
    ## Run the event loop. The poll phase is done only once
    ## Timeout is a thresold and can be taken in account lately
    let timeout = TimeOutWatcher.init(timeoutMs)
    processNextTickCoros(timeout)
    # Phase 1: process timers
    var coroLimitForTimer = 0
    processTimers(coroLimitForTimer, timeout)
    # Phase 2: process pending
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher.pendingCoros.len() == 0 or timeout.expired():
            break
        ActiveDispatcher.pendingCoros.popFirst().resume()
        processNextTickCoros(timeout)
    # Phase 1 again
    processTimers(coroLimitForTimer, timeout)
    # PrePhase 3: calculate the poll timeout
    if timeout.expired:
        return
    var pollTimeoutMs: int
    if not ActiveDispatcher.timers.len() == 0:
        if timeout.hasNoDeadline():
            pollTimeoutMs = clampTimeout(
                inMilliseconds(ActiveDispatcher.timers[0].finishAt - getMonoTime()),
                EvDispatcherTimeoutMs)
        else:
            pollTimeoutMs = clampTimeout(min(
                inMilliseconds(ActiveDispatcher.timers[0].finishAt - getMonoTime()),
                timeout.getRemainingMs()
            ), EvDispatcherTimeoutMs)
    elif not timeout.hasNoDeadline():
        pollTimeoutMs = clampTimeout(timeout.getRemainingMs(), EvDispatcherTimeoutMs)
    else:
        pollTimeoutMs = EvDispatcherTimeoutMs
    # Phase 3: poll for I/O
    while ActiveDispatcher.activeCorosInsideSelector != 0:
        # The event loop could return with no work if an event is triggered with no coroutine
        # If so, we will sleep and loop again
        var readyKeyList = ActiveDispatcher.selector.select(pollTimeoutMs)
        var hasResumedCoro: bool
        if readyKeyList.len() == 0:
            break # timeout expired
        for readyKey in readyKeyList:
            block eventHandler:
                ActiveDispatcher.consumeEvent = false
                var asyncData = getData(ActiveDispatcher.selector, readyKey.fd) 
                var writeList: seq[OneShotCoroutine]
                var readList: seq[OneShotCoroutine]
                if Event.Write in readyKey.events:
                    writeList = move(asyncData.writeList)
                if readyKey.events.card() > 0 and {Event.Write} != readyKey.events:
                    readList = move(asyncData.readList)
                for oneShotCoro in writeList:
                    let coro = oneShotCoro.consumeAndGet(false)
                    if coro != nil:
                        hasResumedCoro = true
                        resume(coro)
                    processNextTickCoros(timeout)
                    if ActiveDispatcher.consumeEvent:
                        break eventHandler
                for oneShotCoro in readList:
                    let coro = oneShotCoro.consumeAndGet(false)
                    if coro != nil:
                        hasResumedCoro = true
                        resume(coro)
                if asyncData.unregisterWhenTriggered:
                    ActiveDispatcher.selector.unregister(readyKey.fd)
        if hasResumedCoro:
            break
        sleep(SleepMsIfInactive)
    # Phase 1 again
    processTimers(coroLimitForTimer, timeout)
    # Phase 4: process "check" coros
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher.checkCoros.len() == 0 or timeout.expired:
            break
        ActiveDispatcher.checkCoros.popFirst().resume()
        processNextTickCoros(timeout)
    # Phase 5: process "close" coros, even if timeout is expired
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher.closeCoros.len() == 0:
            break
        ActiveDispatcher.closeCoros.popFirst().resume()
        processNextTickCoros(timeout)

proc runEventLoop*(
        timeoutMs = -1,
        dispatcher = ActiveDispatcher,
    ) =
    ## The same event loop cannot be run twice.
    ## The event loop will stop when no coroutine is registered inside it
    ## Two kinds of deadlocks can happen when timeoutMs is not set:
    ## - if at least one coroutine waits for an event that never happens
    ## - if a coroutine never stops, or recursivly add coroutines
    if dispatcher[].running:
        raise newException(ValueError, "Cannot run the same event loop twice")
    let oldDispatcher = ActiveDispatcher
    ActiveDispatcher = dispatcher
    dispatcher.running = true
    try:
        let timeout = TimeOutWatcher.init(timeoutMs)
        while not timeout.expired:
            if dispatcher.isDispatcherEmpty():
                break
            runOnce(timeout.getRemainingMs())
    finally:
        dispatcher[].running = false
        ActiveDispatcher = oldDispatcher

template withEventLoop*(body: untyped) =
    let oldDispatcher = ActiveDispatcher
    ActiveDispatcher = newDispatcher()
    `body`
    runEventLoop()
    ActiveDispatcher = oldDispatcher

proc running*(dispatcher = ActiveDispatcher): bool =
    dispatcher[].running


#[ *** Poll fd API *** ]#

proc consumeCurrentEvent*() =
    ## Will prevent other coroutines to resume until the next loop
    ActiveDispatcher.consumeEvent = true

proc registerEvent*(
    ev: SelectEvent,
    coros: seq[OneShotCoroutine],
) =
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    ActiveDispatcher.selector.registerEvent(ev, AsyncData(readList: coros))

proc registerHandle*(
    fd: int | SocketHandle,
    events: set[Event],
): PollFd =
    result = PollFd(fd)
    ActiveDispatcher.selector.registerHandle(fd, events, AsyncData())

proc registerProcess*(
    pid: int,
    coros: seq[OneShotCoroutine],
    unregisterWhenTriggered = true,
): PollFd =
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    result = PollFd(ActiveDispatcher.selector.registerProcess(pid, AsyncData(
            readList: coros,
            unregisterWhenTriggered: unregisterWhenTriggered
        )))

proc registerSignal*(
    signal: int,
    coros: seq[OneShotCoroutine],
    unregisterWhenTriggered = true,
): PollFd =
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    result = PollFd(ActiveDispatcher.selector.registerSignal(signal, AsyncData(
        readList: coros,
        unregisterWhenTriggered: unregisterWhenTriggered
    )))

proc registerTimer*(
    timeoutMs: int,
    coros: seq[OneShotCoroutine],
    oneshot: bool = true,
): PollFd =
    ## Timer is registered inside the poll, not inside the event loop.
    ## Use another function to sleep inside the event loop (more reactive, less overhead for short sleep)
    ## Coroutines will only be resumed once, even if timer is not oneshot. You need to associate them to the fd each time for a periodic action
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    result = PollFd(ActiveDispatcher.selector.registerTimer(timeoutMs, oneshot, AsyncData(
        readList: coros,
        isTimer: true,
        unregisterWhenTriggered: oneshot
    )))

proc unregister*(fd: PollFd) =
    ## It will also consume all coroutines registered inside it
    var asyncData = ActiveDispatcher.selector.getData(fd.int)
    ActiveDispatcher.selector.unregister(fd.int)
    for coro in asyncData.readList:
        coro.removeFromSelector(false)
    for coro in asyncData.writeList:
        coro.removeFromSelector(false)

proc addInsideSelector*(fd: PollFd, oneShotCoro: OneShotCoroutine, event: Event) =
    ## Not thread safe
    ## Will not update the type event listening
    oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    if event == Event.Write:
        ActiveDispatcher.selector.getData(fd.int).writeList.add(oneShotCoro)
    else:
        ActiveDispatcher.selector.getData(fd.int).readList.add(oneShotCoro)

proc addInsideSelector*(fd: PollFd, coros: seq[OneShotCoroutine], event: Event) =
    ## Not thread safe
    ## Will not update the type event listening
    for oneShotCoro in coros:
        oneShotCoro.notifyRegistration(ActiveDispatcher, true)
    if event == Event.Write:
        ActiveDispatcher.selector.getData(fd.int).writeList.add(coros)
    else:
        ActiveDispatcher.selector.getData(fd.int).readList.add(coros)

proc updatePollFd*(fd: PollFd, events: set[Event]) =
    ## Not thread safe
    ActiveDispatcher.selector.updateHandle(fd.int, events)

proc sleepAsync*(timeoutMs: int) =
    let coro = getCurrentCoroutine()
    if coro.isNil():
        let timeout = TimeOutWatcher.init(timeoutMs)
        while not timeout.expired():
            runEventLoop(timeout.getRemainingMs())
    else:
        resumeOnTimer(coro.toOneShot(), timeoutMs)
        suspend(coro)

proc suspendUntilRead*(fd: PollFd, timeoutMs = -1, consumeEvent = true): bool =
    ## See also `consumeCurrentEvent` to avoid a data race if multiple coros are registered for same fd
    ## If PollFd is not a file, by definition only the coros in the readList will be resumed
    ## It will not try to update the kind of event waited inside the selector. Waiting for unregistered event will deadlock
    let coro = getCurrentCoroutine()
    if coro.isNil():
        # We are not inside the dispatcher
        let timeout = TimeOutWatcher.init(timeoutMs)
        let oneShotCoro = toOneShot(nil)
        addInsideSelector(fd, oneShotCoro, Event.Read)
        while true:
            runEventLoop(timeout.getRemainingMs())
            if oneShotCoro.cancelled:
                if consumeEvent:
                    consumeCurrentEvent()
                return true
            if timeout.expired():
                let coro = oneShotCoro.consumeAndGet(false)
                if coro != nil:
                    resume(coro)
                return false
    elif timeoutMs == -1:
        addInsideSelector(fd, toOneShot(coro), Event.Read)
        suspend()
        if consumeEvent:
            consumeCurrentEvent()
        return true
    else:
        let oneShotCoro = toOneShot(coro)
        addInsideSelector(fd, oneShotCoro, Event.Read)
        resumeOnTimer(oneShotCoro, timeoutMs)
        suspend()
        if oneShotCoro.cancelledByTimer:
            return false
        else:
            if consumeEvent:
                consumeCurrentEvent()
            return true

proc suspendUntilWrite*(fd: PollFd, timeoutMs = -1, consumeEvent = true): bool =
    ## If PollFd is not a file, by definition only the coros in the readList will be resumed
    ## It will not try to update the kind of event waited inside the selector. Waiting for unregistered event will deadlock
    ## consumeEvent permits to avoid a data race if multiple coros are registered for same fd
    let coro = getCurrentCoroutine()
    if coro.isNil():
        # We are not inside the dispatcher
        let timeout = TimeOutWatcher.init(timeoutMs)
        let oneShotCoro = toOneShot(nil)
        addInsideSelector(fd, oneShotCoro, Event.Write)
        while true:
            runEventLoop(timeout.getRemainingMs())
            if oneShotCoro.cancelled:
                if consumeEvent:
                    consumeCurrentEvent()
                return true
            if timeout.expired():
                let coro = oneShotCoro.consumeAndGet(false)
                if coro != nil:
                    resume(coro)
                return false
    elif timeoutMs == -1:
        addInsideSelector(fd, toOneShot(coro), Event.Write)
        suspend()
        if consumeEvent:
            consumeCurrentEvent()
        return true
    else:
        let oneShotCoro = toOneShot(coro)
        addInsideSelector(fd, oneShotCoro, Event.Write)
        resumeOnTimer(oneShotCoro, timeoutMs)
        suspend()
        if oneShotCoro.cancelledByTimer:
            return false
        else:
            if consumeEvent:
                consumeCurrentEvent()
            return true