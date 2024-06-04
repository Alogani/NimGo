import ../[coroutines, eventdispatcher]
import ../private/[coroutinepool, timeoutwatcher]
import std/[options, macros]

export options

var coroPool = CoroutinePool()

type
    NextCoroutine = ref object
        coro: OneShotCoroutine

    GoTask*[T] = ref object
        coro: Coroutine
        next: NextCoroutine


proc goAsyncImpl(next: NextCoroutine, fn: proc()): GoTask[void] {.discardable.} =
    #var coro = coroPool.acquireCoro(fn)
    var coro = newCoroutine(fn)
    resumeLater(coro)
    return GoTask[void](coro: coro, next: next)

proc goAsyncImpl[T](next: NextCoroutine, fn: proc(): T): GoTask[T] =
    #var coro = coroPool.acquireCoro(fn)
    var coro = newCoroutine(fn)
    resumeLater(coro)
    return GoTask[T](coro: coro, next: next)

template goAsync*(fn: untyped): auto =
    # Hard to do it without macro
    # But this one is fast to compile (and called less often than async/await)
    let next = NextCoroutine()
    goAsyncImpl(next,
        proc(): auto =
            when typeof(`fn`) is void:
                `fn`
            elif typeof(`fn`) is proc(): void {.closure.} or typeof(`fn`) is proc(): void {.nimcall.}:
                `fn`()
            elif typeof(`fn`) is proc {.closure.} or typeof(`fn`) is proc {.nimcall.}:
                result = `fn`()
            else:
                result = `fn`
            if next.coro != nil:
                let coro = next.coro.consumeAndGet()
                if coro != nil:
                    resumeLater(coro)
    )

proc finished*[T](gotask: GoTask[T]): bool =
    gotask.coro.finished()

proc waitImpl[T](gotask: GoTask[T], timeoutMs = -1) =
    if not gotask.coro.finished():
        var timeout = initTimeOutWatcher(timeoutMs)
        let coro = getCurrentCoroutine()
        if coro == nil:
            while not gotask.coro.finished():
                runOnce(timeout.getRemainingMs())
                if timeout.expired():
                    break
        else:
            let oneShotCoro = coro.toOneShot()
            gotask.next.coro = oneShotCoro
            if timeoutMs != -1:
                resumeOnTimer(oneShotCoro, timeoutMs)
            suspend(coro)

proc wait*[T](gotask: GoTask[T], timeoutMs = -1): Option[T] =
    waitImpl(goTask, timeoutMs)
    if gotask.coro.getState() != CsFinished:
        return none(T)
    else:
        return some(getReturnVal[T](gotask.coro))

proc wait*[T](gotask: GoTask[T]): T =
    waitImpl(goTask, -1)
    return getReturnVal[T](gotask.coro)

proc wait*(gotask: GoTask[void], timeoutMs: int): bool =
    waitImpl(goTask, timeoutMs)
    if gotask.coro.getState() != CsFinished:
        return false
    else:
        return true

proc wait*(gotask: GoTask[void]) =
    waitImpl(goTask, -1)

proc waitAllImpl[T](gotasks: seq[GoTask[T]], timeoutMs = -1): bool =
    let coro = getCurrentCoroutine()
    var timeout = initTimeOutWatcher(timeoutMs)
    while true:
        var allFinished = true
        for task in gotasks:
            if task.coro.getState() != CsFinished:
                allFinished = false
        if allFinished:
            return true
        if timeout.expired():
            return false
        if coro == nil:
            runOnce(timeout.getRemainingMs())
        else:
            resumeLater(coro)
            suspend(coro)

proc waitAll*[T](gotasks: seq[GoTask[T]], timeoutMs = -1): seq[T] =
    if not waitAllImpl(gotasks, timeoutMs):
        return
    result = newSeqOfCap[T](gotasks.len())
    for task in gotasks:
        result.add getReturnVal[T](task.coro)

proc waitAll*(gotasks: seq[GoTask[void]], timeoutMs: int): bool =
    return waitAllImpl(gotasks, timeoutMs)

proc waitAll*(gotasks: seq[GoTask[void]]) =
    discard waitAllImpl(gotasks, -1)

proc waitAny*[T](gotasks: seq[GoTask[T]], timeoutMs = -1): bool =
    ## Ignores failed gotasks, return false if all failed
    let coro = getCurrentCoroutine()
    var timeout = initTimeOutWatcher(timeoutMs)
    while true:
        var allFailed = true
        for task in gotasks:
            let coroState = task.coro.getState()
            if coroState == CsFinished:
                return true
        if allFailed or timeout.expired():
            return false
        if coro == nil:
            runOnce(timeout.getRemainingMs())
        else:
            resumeLater(coro)
            suspend(coro)
    