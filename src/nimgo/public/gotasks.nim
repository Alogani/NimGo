import ../[coroutines, eventdispatcher]
import ../private/timeoutwatcher
#import ../private/[coroutinepool]
import std/[options, macros]

export options

#var coroPool = CoroutinePool()

type
    Callbacks = ref object
        list: seq[OneShotCoroutine]

    GoTaskObj = object of RootObj
        coro: Coroutine
        callbacks: Callbacks

    GoTaskUntyped* = ref GoTaskObj
    GoTask*[T] = GoTaskUntyped

#[
## Coroutine Pool is actually causing a bug
when defined(nimAllowNonVarDestructor):
    proc `=destroy`(gotaskObj: GoTaskObj) =
        coroPool.releaseCoro(gotaskObj.coro)
else:
    proc `=destroy`(gotaskObj: var GoTaskObj) =
        coroPool.releaseCoro(gotaskObj.coro)
]#

proc goAsyncImpl(callbacks: Callbacks, fn: proc()): GoTask[void] =
    #var coro = coroPool.acquireCoro(fn)
    var coro = newCoroutine(fn)
    resumeLater(coro)
    return GoTask[void](coro: coro, callbacks: callbacks)

proc goAsyncImpl[T](callbacks: Callbacks, fn: proc(): T): GoTask[T] =
    #var coro = coroPool.acquireCoro(fn)
    var coro = newCoroutine(fn)
    resumeLater(coro)
    return GoTask[T](coro: coro, callbacks: callbacks)

macro goAsync*(fn: typed): untyped =
    if fn.kind == nnkCall:
        let fnType = getType(fn)
        let closureSym = genSym(nskProc)
        if fnType.strVal() == "void":
            return quote do:
                proc `closureSym`(): GoTask[void] {.discardable.} =
                    let callbacks = Callbacks()
                    result = goAsyncImpl(
                        callbacks,
                        proc() =
                            `fn`
                            for cb in callbacks.list:
                                let coro = cb.consumeAndGet()
                                if coro != nil:
                                    resumeLater(coro)
                    )
                `closureSym`()
        else:
            return quote do:
                proc `closureSym`(): GoTask[`fnType`] =
                    let callbacks = Callbacks()
                    result = goAsyncImpl(
                        callbacks,
                        proc(): `fnType` =
                            result = `fn`
                            for cb in callbacks.list:
                                let coro = cb.consumeAndGet()
                                if coro != nil:
                                    resumeLater(coro)
                    )
                `closureSym`()
    let symType = getType(fn)
    let declarationVal = symType[0].strVal()
    if declarationVal != "proc" and declarationVal != "func":
        error("Expected a function or a call")
    let fnType = symType[1]
    let closureSym = genSym(nskProc)
    if fnType.strVal() == "void":
        return quote do:
            proc `closureSym`(): GoTask[void] {.discardable.} =
                let callbacks = Callbacks()
                result = goAsyncImpl(
                    callbacks,
                    proc() =
                        `fn`()
                        for cb in callbacks.list:
                            let coro = cb.consumeAndGet()
                            if coro != nil:
                                resumeLater(coro)
                )
            `closureSym`()
    else:
        return quote do:
            proc `closureSym`(): GoTask[`fnType`] =
                let callbacks = Callbacks()
                result = goAsyncImpl(
                    callbacks,
                    proc(): `fnType` =
                        result = `fn`()
                        for cb in callbacks.list:
                            let coro = cb.consumeAndGet()
                            if coro != nil:
                                resumeLater(coro)
                )
            `closureSym`()


proc finished*(gotask: GoTaskUntyped): bool =
    gotask.coro.finished()

proc finished*[T](gotask: GoTask[T]): bool =
    gotask.coro.finished()

proc waitAnyImpl(currentCoro: Coroutine, gotasks: seq[GoTaskUntyped], timeoutMs: int): bool =
    let sleeper = toOneShot(currentCoro)
    var timeout = initTimeoutWatcher(timeoutMs)
    for task in gotasks:
        if task.finished():
            discard sleeper.consumeAndGet()
            return
        task.callbacks.list.add(sleeper)
    if currentCoro == nil:
        while not sleeper.hasBeenResumed():
            runOnce()
            if timeout.expired():
                return false
    else:
        if timeoutMs != -1:
            resumeOnTimer(sleeper, timeoutMs)
        suspend(currentCoro)
    if timeoutMs == -1:
        return true
    ## Not really good:
    return timeout.getRemainingMs() != 0

proc wait*[T](gotask: GoTask[T], timeoutMs: Positive): Option[T] =
    if not waitAnyImpl(getCurrentCoroutine(), @[GoTaskUntyped(gotask)], timeoutMs):
        return none(T)
    else:
        return some(getReturnVal[T](gotask.coro))

proc wait*[T](gotask: GoTask[T]): T =
    discard waitAnyImpl(getCurrentCoroutine(), @[gotask], -1)
    return getReturnVal[T](gotask.coro)

proc wait*(gotask: GoTask[void], timeoutMs: Positive): bool =
    return waitAnyImpl(getCurrentCoroutine(), @[GoTaskUntyped(gotask)], timeoutMs)

proc wait*(gotask: GoTask[void]) =
    discard waitAnyImpl(getCurrentCoroutine(), @[gotask], -1)

proc waitAllImpl[T](gotasks: seq[GoTask[T]], timeoutMs: Positive): bool =
    let currentCoro = getCurrentCoroutine()
    if timeoutMs == -1:
        for task in gotasks:
            if not task.finished():
                discard waitAnyImpl(currentCoro, @[task], -1)
    else:
        var timeout = initTimeoutWatcher(timeoutMs)
        for task in gotasks:
            if not task.finished():
                if not waitAnyImpl(currentCoro, @[GoTaskUntyped(task)], timeout.getRemainingMs()):
                    return false
    return true

proc waitAll*[T](gotasks: seq[GoTask[T]], timeoutMs = -1): seq[T] =
    if not waitAllImpl(gotasks, timeoutMs):
        return
    result = newSeqOfCap[T](gotasks.len())
    for task in gotasks:
        result.add getReturnVal[T](task.coro)

proc waitAll*(gotasks: seq[GoTask[void]], timeoutMs: Positive): bool =
    return waitAllImpl(gotasks, timeoutMs)

proc waitAll*(gotasks: seq[GoTask[void]]) =
    discard waitAllImpl(gotasks, -1)

proc waitAny*[T](gotasks: seq[GoTask[T]], timeoutMs: Positive): bool =
    return waitAnyImpl(getCurrentCoroutine(), gotasks, timeoutMs)

proc waitAny*[T](gotasks: seq[GoTask[T]]) =
    waitAnyImpl(getCurrentCoroutine(), gotasks, -1)

template goAndwait*(fn: untyped): untyped =
    ## Shortcut for wait goAsync
    wait(goAsync(`fn`))

proc addCallback*(goTask: GoTaskUntyped, oneShotCoro: OneShotCoroutine) =
    if goTask.finished():
        let coro = oneShotCoro.consumeAndGet()
        if coro != nil:
            resumeLater(coro)
    else:
        gotask.callbacks.list.add oneShotCoro

proc resumeAfter*(goTask: GoTaskUntyped) =
    var coro = getCurrentCoroutineSafe()
    addCallback(goTask, toOneShot(coro))
    suspend(coro)
