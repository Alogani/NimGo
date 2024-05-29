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


const EvDispatcherTimeoutMs {.intdefine.} = 50 # We don't block on poll phase if new coros were registered
const SleepMsIfInactive = 20 # to avoid busy waiting. When selector is not empty, but events triggered with no associated coroutines
const SleepMsIfEmpty = 40 # to avoid busy waiting. When the event loop is empty
const CoroLimitByPhase = 30 # To avoid starving the coros inside the poll


type
    AsyncData = object
        readList: seq[Coroutine] # Also stores all other event kind
        writeList: seq[Coroutine]
        unregisterWhenTriggered: bool

    PollFd* = distinct int
        ## Reprensents a descriptor registered in the EventDispatcher: file handle, signal, timer, etc.
    
    ConsummableCoroutine* = ref object
        coro: Coroutine

    CoroutineWithTimer = tuple[finishAt: MonoTime, coro: ConsummableCoroutine]

    EvDispatcherObj = object
        running: bool
        ## Phases
        corosCountInSelector: int
        selector: Selector[AsyncData]
        onNextTickCoros: Deque[Coroutine]
        timers: HeapQueue[CoroutineWithTimer] # Thresold and not exact time
        timersCancelledCountInQueue: int
        pendingCoros: Deque[Coroutine]
        checkCoros: Deque[Coroutine]
        closeCoros: Deque[Coroutine]
    EvDispatcher* = ref EvDispatcherObj
        ## Cannot be shared or moved around threads

var ActiveDispatcher {.threadvar.}: EvDispatcher


#[ *** CancellableCoroutine API *** ]#

proc `<`(a, b: CoroutineWithTimer): bool =
    a.finishAt < b.finishAt

proc initConsummableCoro*(coro: Coroutine): ConsummableCoroutine =
    ConsummableCoroutine(
        coro: coro
    )

proc consumeAndGet*(consummable: ConsummableCoroutine): Coroutine =
    result = consummable.coro
    if result != nil:
        ActiveDispatcher.timersCancelledCountInQueue += 1
        consummable.coro = nil

proc consumeAndResume*(consummable: ConsummableCoroutine) =
    ## Will prevent any further resumes. Don't resume if already consumed
    ## Notify the event loop that the coroutine is consummed and shall not be waited
    let coro = consummable.consumeAndGet()
    if coro != nil:
        resume(coro)

proc consumeAndResumeInsideEv(consummable: ConsummableCoroutine) =
    ##  Will prevent any further resumes. Don't resume if already consumed
    let coro = consummable.coro
    if coro == nil:
        ActiveDispatcher.timersCancelledCountInQueue -= 1
    else:
        consummable.coro = nil
        resume(coro)

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
    dispatcher[].corosCountInSelector == 0 and
        dispatcher[].onNextTickCoros.len() == 0 and
        dispatcher[].timers.len() == 0 and
        dispatcher[].pendingCoros.len() == 0 and
        dispatcher[].checkCoros.len() == 0 and
        dispatcher[].closeCoros.len() == 0

proc processNextTickCoros(timeout: TimeOutWatcher) {.inline.} =
    while not (ActiveDispatcher[].onNextTickCoros.len() == 0 or timeout.expired):
        ActiveDispatcher[].onNextTickCoros.popFirst().resume()

proc processTimers(coroLimitForTimer: var int, timeout: TimeOutWatcher) =
    while coroLimitForTimer < CoroLimitByPhase or ActiveDispatcher[].corosCountInSelector == 0:
        if timeout.expired():
            break
        if ActiveDispatcher[].timers.len() == 0:
            ## Blazingly faster than getMonoTime
            break
        var monoTimeNow = getMonoTime()
        var hasResumed = false
        # // TODO: Cancellable coroutines ?
        if ActiveDispatcher[].timers.len() != 0:
            if monoTimeNow > ActiveDispatcher[].timers[0].finishAt:
                hasResumed = true
                ActiveDispatcher[].timers.pop().coro.consumeAndResumeInsideEv()
                processNextTickCoros(timeout)
                coroLimitForTimer += 1
                #monoTimeNow = getMonoTime()
        if not hasResumed:
            break

proc runOnce*(timeoutMs: int) =
    ## Run the event loop. The poll phase is done only once
    ## Timeout is a thresold and can be taken in account lately
    let timeout = TimeOutWatcher.init(timeoutMs)
    processNextTickCoros(timeout)
    # Phase 1: process timers
    var coroLimitForTimer = 0
    processTimers(coroLimitForTimer, timeout)
    # Phase 2: process pending
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher[].pendingCoros.len() == 0 or timeout.expired():
            break
        ActiveDispatcher[].pendingCoros.popFirst().resume()
        processNextTickCoros(timeout)
    # Phase 1 again
    processTimers(coroLimitForTimer, timeout)
    # PrePhase 3: calculate the poll timeout
    if timeout.expired:
        return
    var pollTimeoutMs: int
    if not ActiveDispatcher[].timers.len() == 0:
        if timeout.hasNoDeadline():
            pollTimeoutMs = clampTimeout(
                inMilliseconds(ActiveDispatcher[].timers[0].finishAt - getMonoTime()),
                EvDispatcherTimeoutMs)
        else:
            pollTimeoutMs = clampTimeout(min(
                inMilliseconds(ActiveDispatcher[].timers[0].finishAt - getMonoTime()),
                timeout.getRemainingMs()
            ), EvDispatcherTimeoutMs)
    elif not timeout.hasNoDeadline():
        pollTimeoutMs = clampTimeout(timeout.getRemainingMs(), EvDispatcherTimeoutMs)
    else:
        pollTimeoutMs = EvDispatcherTimeoutMs
    # Phase 3: poll for I/O
    while ActiveDispatcher[].corosCountInSelector != 0:
        # The event loop could return with no work if an event is triggered with no coroutine
        # If so, we will sleep and loop again
        var readyKeyList = ActiveDispatcher[].selector.select(pollTimeoutMs)
        var hasResumedCoro: bool
        if readyKeyList.len() == 0:
            break # timeout expired
        for readyKey in readyKeyList:
            var asyncData = getData(ActiveDispatcher[].selector, readyKey.fd)
            var writeList: seq[Coroutine]
            var readList: seq[Coroutine]
            if Event.Write in readyKey.events:
                writeList = move(asyncData.writeList)
            if readyKey.events.card() > 0 and {Event.Write} != readyKey.events:
                readList = move(asyncData.readList)
            ActiveDispatcher[].corosCountInSelector -= writeList.len() + readList.len()
            if writeList.len() > 0 or readList.len() > 0:
                hasResumedCoro = true
            for coro in writeList:
                coro.resume()
                processNextTickCoros(timeout)
            for coro in readList:
                coro.resume()
                processNextTickCoros(timeout)
            if asyncData.unregisterWhenTriggered:
                ActiveDispatcher[].selector.unregister(readyKey.fd)
        if hasResumedCoro:
            break
        sleep(SleepMsIfInactive)
    # Phase 1 again
    processTimers(coroLimitForTimer, timeout)
    # Phase 4: process "check" coros
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher[].checkCoros.len() == 0 or timeout.expired:
            break
        ActiveDispatcher[].checkCoros.popFirst().resume()
        processNextTickCoros(timeout)
    # Phase 5: process "close" coros, even if timeout is expired
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher[].closeCoros.len() == 0:
            break
        ActiveDispatcher[].closeCoros.popFirst().resume()
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
            else:
                sleep(SleepMsIfEmpty)
            runOnce(timeout.getRemainingMs())
    finally:
        dispatcher[].running = false
        ActiveDispatcher = oldDispatcher

template withEventLoop*(body: untyped) =
    let dispatcher = newDispatcher()
    `body`
    runEventLoop(dispatcher)

proc running*(dispatcher = ActiveDispatcher): bool =
    dispatcher[].running


#[ *** Coroutine API *** ]#

proc resumeSoon*(coro: Coroutine) =
    ## Will register in the "pending phase"
    ActiveDispatcher[].pendingCoros.addLast coro

proc resumeOnTimer*(coro: Coroutine, timeoutMs: int): ConsummableCoroutine {.discardable.} =
    ## Equivalent to a sleep directly handled by the dispatcher
    ## Returns an optional consummable object
    result = initConsummableCoro(coro)
    ActiveDispatcher[].timers.push(
        (getMonoTime() + initDuration(milliseconds = timeoutMs),
        result)
    )

proc resumeOnNextTick*(coro: Coroutine) =
    ActiveDispatcher[].onNextTickCoros.addLast coro

proc resumeOnCheckPhase*(coro: Coroutine) =
    ActiveDispatcher[].checkCoros.addLast coro

proc resumeOnClosePhase*(coro: Coroutine) =
    ActiveDispatcher[].closeCoros.addLast coro


#[ *** Poll fd API *** ]#

proc registerEvent*(
    ev: SelectEvent,
    coros: seq[Coroutine] = @[],
) =
    if coros.len() > 0: ActiveDispatcher[].corosCountInSelector += coros.len()
    ActiveDispatcher[].selector.registerEvent(ev, AsyncData(readList: coros))

proc registerHandle*(
    fd: int | SocketHandle,
    events: set[Event],
): PollFd =
    result = PollFd(fd)
    ActiveDispatcher[].selector.registerHandle(fd, events, AsyncData())

proc registerProcess*(
    pid: int,
    coros: seq[Coroutine] = @[],
    unregisterWhenTriggered = true,
): PollFd =
    if coros.len() > 0: ActiveDispatcher[].corosCountInSelector += coros.len()
    result = PollFd(ActiveDispatcher[].selector.registerProcess(pid, AsyncData(
            readList: coros,
            unregisterWhenTriggered: unregisterWhenTriggered
        )))

proc registerSignal*(
    signal: int,
    coros: seq[Coroutine] = @[],
    unregisterWhenTriggered = true,
): PollFd =
    if coros.len() > 0: ActiveDispatcher[].corosCountInSelector += coros.len()
    result = PollFd(ActiveDispatcher[].selector.registerSignal(signal, AsyncData(
        readList: coros,
        unregisterWhenTriggered: unregisterWhenTriggered
    )))

proc registerTimer*(
    timeoutMs: int,
    oneshot: bool = true,
    coros: seq[Coroutine] = @[],
): PollFd =
    ## Timer is registered inside the poll, not inside the event loop.
    ## Use another function to sleep inside the event loop (more reactive, less overhead for short sleep)
    ## Coroutines will only be resumed once, even if timer is not oneshot. You need to associate them to the fd each time for a periodic action
    if coros.len() > 0: ActiveDispatcher[].corosCountInSelector += coros.len()
    result = PollFd(ActiveDispatcher[].selector.registerTimer(timeoutMs, oneshot, AsyncData(
        readList: coros,
        unregisterWhenTriggered: oneshot
    )))

proc unregister*(fd: PollFd) =
    var asyncData = ActiveDispatcher[].selector.getData(fd.int)
    ActiveDispatcher[].selector.unregister(fd.int)
    ActiveDispatcher[].corosCountInSelector -= asyncData.readList.len() + asyncData.writeList.len()
    # If readList or writeList contains coroutines, they should be destroyed thanks to sharedPtr

proc addInsideSelector*(fd: PollFd, coro: seq[Coroutine], event: Event) =
    ## Not thread safe
    ## Will not update the type event listening
    ActiveDispatcher[].corosCountInSelector += 1
    if event == Event.Write:
        ActiveDispatcher[].selector.getData(fd.int).writeList.add(coro)
    else:
        ActiveDispatcher[].selector.getData(fd.int).readList.add(coro)

proc addInsideSelector*(fd: PollFd, coro: Coroutine, event: Event) =
    ## Not thread safe
    ## Will not update the type event listening
    ActiveDispatcher[].corosCountInSelector += 1
    if event == Event.Write:
        ActiveDispatcher[].selector.getData(fd.int).writeList.add(coro)
    else:
        ActiveDispatcher[].selector.getData(fd.int).readList.add(coro)

proc updatePollFd*(fd: PollFd, events: set[Event]) =
    ## Not thread safe
    ActiveDispatcher[].selector.updateHandle(fd.int, events)

proc suspendUntilRead*(fd: PollFd) =
    ## If multiple coros are suspended for the same PollFd and one consume it, the others will deadlock
    ## If PollFd is not a file, by definition only the coros in the readList will be resumed
    let coro = getCurrentCoroutine()
    #if coro.isNil(): raise newException(ValueError, "Can only suspend inside a coroutine")
    addInsideSelector(fd, coro, Event.Read)
    suspend()

proc suspendUntilWrite*(fd: PollFd) =
    ## If multiple coros are suspended for the same PollFd and one consume it, the others will deadlock
    ## If PollFd is not a file, by definition only the coros in the readList will be resumed
    let coro = getCurrentCoroutine()
    #if coro.isNil(): raise newException(ValueError, "Can only suspend inside a coroutine")
    addInsideSelector(fd, coro, Event.Write)
    suspend()
