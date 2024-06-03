import ../[eventdispatcher]
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
    var coro = coroPool.acquireCoro(fn)
    resumeSoon(coro)
    return GoTask[void](coro: coro, next: next)

proc goAsyncImpl[T](next: NextCoroutine, fn: proc(): T): GoTask[T] =
    var coro = coroPool.acquireCoro(fn)
    resumeSoon(coro)
    return GoTask[T](coro: coro, next: next)

template goAsync*(fn: untyped) =
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
                    resumeSoon(coro)
    )

proc finished*[T](gotask: GoTask[T]): bool =
    gotask.coro.finished()

proc waitImpl[T](gotask: GoTask[T], timeoutMs = -1) =
    if not gotask.coro.finished():
        let timeout = TimeOutWatcher.init(timeoutMs)
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

proc wait*(gotask: GoTask[void], timeoutMs = -1): bool =
    waitImpl(goTask, timeoutMs)
    if gotask.coro.getState() != CsFinished:
        return false
    else:
        return true

proc waitAllImpl[T](gotasks: seq[GoTask[T]], timeoutMs = -1): bool =
    let coro = getCurrentCoroutine()
    let timeout = TimeOutWatcher.init(timeoutMs)
    while true:
        var allFinished = true
        for task in gotasks:
            let coroState = task.coro.getState()
            if coroState == CsDead:
                return false
            elif coroState != CsFinished:
                allFinished = false
        if allFinished:
            return true
        if timeout.expired():
            return false
        if coro == nil:
            runOnce(timeout.getRemainingMs())
        else:
            resumeOnClosePhase(coro)
            suspend(coro)

proc waitAll*[T](gotasks: seq[GoTask[T]], timeoutMs = -1): seq[T] =
    ## Fails fast. In case of fail, seq[T].len() == 0
    if not waitAllImpl(gotasks, timeoutMs):
        return
    result = newSeqOfCap[T](gotasks.len())
    for task in gotasks:
        result.add getReturnVal[T](task.coro)

proc waitAll*(gotasks: seq[GoTask[void]], timeoutMs = -1): bool =
    ## Fails fast. In case of fail, return false
    return waitAllImpl(gotasks, timeoutMs)

proc waitAny*[T](gotasks: seq[GoTask[T]], timeoutMs = -1): bool =
    ## Ignores failed gotasks, return false if all failed
    let coro = getCurrentCoroutine()
    let timeout = TimeOutWatcher.init(timeoutMs)
    while true:
        var allFailed = true
        for task in gotasks:
            let coroState = task.coro.getState()
            if coroState == CsFinished:
                return true
            elif coroState != CsDead:
                allFailed = false
        if allFailed or timeout.expired():
            return false
        if coro == nil:
            runOnce(timeout.getRemainingMs())
        else:
            resumeOnClosePhase(coro)
            suspend(coro)
    