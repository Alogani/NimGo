import ../[coroutines, eventdispatcher]
import ../private/[coroutinepool]
import std/[options, macros]

export options

var coroPool = CoroutinePool()

type
    Callbacks = ref object
        list: seq[OneShotCoroutine]

    GoTaskObj = object of RootObj
        coro: Coroutine
        callbacks: Callbacks

    GoTaskUntyped = ref GoTaskObj
    GoTask*[T] = GoTaskUntyped

#[
## Actually causing a bug
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

proc sleepTask*(timeoutMs: int): GoTask[void] =
    ## This is the only task the dispatcher won't wait for
    let callbacks = Callbacks()
    let coro = newCoroutine(proc() =
        for cb in callbacks.list:
            let coro = cb.consumeAndGet()
            if coro != nil:
                resumeLater(coro)
    )
    resumeOnTimer(coro, timeoutMs, willBeAwaited = false)
    return GoTask[void](
        coro: coro,
        callbacks: callbacks,
    )

proc finished*(gotask: GoTaskUntyped): bool =
    gotask.coro.finished()

proc finished*[T](gotask: GoTask[T]): bool =
    gotask.coro.finished()

proc waitAnyImpl(currentCoro: Coroutine, gotasks: seq[GoTaskUntyped]) =
    let sleeper = toOneShot(currentCoro)
    for task in gotasks:
        if task.finished():
            discard sleeper.consumeAndGet()
            return
        task.callbacks.list.add(sleeper)
    if currentCoro == nil:
        while not sleeper.hasBeenResumed():
            runOnce()
    else:
        suspend(currentCoro)

proc wait*[T](gotask: GoTask[T], canceller: GoTaskUntyped): Option[T] =
    waitAnyImpl(getCurrentCoroutine(), @[gotask, canceller])
    if canceller.finished():
        return none(T)
    else:
        return some(getReturnVal[T](gotask.coro))

proc wait*[T](gotask: GoTask[T]): T =
    waitAnyImpl(getCurrentCoroutine(), @[gotask])
    return getReturnVal[T](gotask.coro)

proc wait*(gotask: GoTask[void], canceller: GoTaskUntyped): bool =
    waitAnyImpl(getCurrentCoroutine(), @[gotask, canceller])
    if canceller.finished():
        return false
    return true

proc wait*(gotask: GoTask[void]) =
    waitAnyImpl(getCurrentCoroutine(), @[gotask])

proc waitAllImpl[T](gotasks: seq[GoTask[T]], canceller: GoTaskUntyped): bool =
    let currentCoro = getCurrentCoroutine()
    if canceller == nil:
        for task in gotasks:
            if not task.finished():
                waitAnyImpl(currentCoro, @[task])
    else:
        for task in gotasks:
            if not task.finished():
                waitAnyImpl(currentCoro, @[task, canceller])
                if canceller.finished():
                    return false
    return true

proc waitAll*[T](gotasks: seq[GoTask[T]], canceller: GoTaskUntyped): seq[T] =
    if not waitAllImpl(gotasks, canceller):
        return
    result = newSeqOfCap[T](gotasks.len())
    for task in gotasks:
        result.add getReturnVal[T](task.coro)

proc waitAll*(gotasks: seq[GoTask[void]], canceller: GoTaskUntyped): bool =
    return waitAllImpl(gotasks, canceller)

proc waitAll*(gotasks: seq[GoTask[void]]) =
    discard waitAllImpl(gotasks, nil)

proc waitAny*[T](gotasks: seq[GoTask[T]], canceller: GoTaskUntyped): bool =
    var allTasks = newSeqOfCap[GoTaskUntyped](gotasks.len() + 1)
    allTasks.add gotasks
    allTasks.add canceller
    waitAnyImpl(getCurrentCoroutine(), allTasks)
    if canceller.finished():
        return false
    return true

proc waitAny*[T](gotasks: seq[GoTask[T]]) =
    waitAnyImpl(getCurrentCoroutine(), gotasks)

template goAndwait*(fn: untyped): untyped =
    ## Shortcut for wait goAsync
    wait(goAsync(`fn`))