import ../[eventdispatcher]
import ../private/[coroutinepool, timeoutwatcher]
import std/options

var coroPool = CoroutinePool()

type
    GoTask*[T] = ref object
        coro: Coroutine


proc goAsyncImpl(fn: proc()): GoTask[void] {.discardable.} =
    var coro = coroPool.acquireCoro(fn)
    resumeSoon(coro)
    return GoTask[void](coro: coro)

proc goAsyncImpl[T](fn: proc(): T): GoTask[T] {.discardable.} =
    var coro = coroPool.acquireCoro(fn)
    resumeSoon(coro)
    return GoTask[T](coro: coro)

template goAsync*(fn: untyped) =
    # Hard to do it without macro
    # But this one is fast to compile (and called less often than async/await)
    goAsyncImpl(
        proc(): auto =
            `fn`
    )

proc finished*[T](gotask: GoTask[T]): bool =
    gotask.coro.finished()

proc wait*[T](gotask: GoTask[T], timeoutMs = -1): Option[T] =
    ## /TODO : use next instead
    let timeout = TimeOutWatcher.init(timeoutMs)
    while not gotask.coro.finished():
        runOnce(timeout.getRemainingMs())
    if gotask.coro.getState() != CsFinished:
        return none(T)
    else:
        return some(getReturnVal[T](gotask.coro))

proc wait*(gotask: GoTask[void], timeoutMs = -1): bool =
    let timeout = TimeOutWatcher.init(timeoutMs)
    while not gotask.coro.finished:
        runOnce(timeout.getRemainingMs())
    if gotask.coro.getState() != CsFinished:
        return false
    else:
        return true

proc waitAll*[T](gotasks: seq[GoTask[T]], timeoutMs = -1): seq[T] =
    ## Fails fast. In case of fail, seq[T].len() == 0
    result = newSeqOfCap(gotasks.len())
    let timeout = TimeOutWatcher.init(timeoutMs)
    while true:
        var allFinished = true
        for task in gotasks:
            let coroState = task.coro.getState()
            if coroState == CsDead:
                return
            elif coroState != CsFinished:
                allFinished = false
        if allFinished:
            break
        if timeout.expired():
            return
        runOnce(timeout.getRemainingMs())
    for task in gotasks:
        result.add task.coro.getReturnVal().unsafeGet()

proc waitAll*(gotasks: seq[GoTask[void]], timeoutMs = -1): bool =
    ## Fails fast. In case of fail, seq[T].len() == 0
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
        runOnce(timeout.getRemainingMs())

proc waitAny*[T](gotasks: seq[GoTask[T]], timeoutMs = -1): bool =
    ## Ignores failed gotasks, return false if all failed
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
        runOnce(timeout.getRemainingMs())

proc waitAny*(gotasks: seq[GoTask[void]], timeoutMs = -1): bool =
    waitAny[void](gotasks, timeoutMs)
