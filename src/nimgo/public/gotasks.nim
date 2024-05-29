import ../[eventdispatcher]
import ../private/coroutinepool
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

proc wait*[T](gotask: GoTask[T]): Option[T] =
    while not gotask.coro.finished:
        runOnce()
    if gotask.coro.getState() == CsDead:
        return none(T)
    else:
        return some(getReturnVal[T](gotask.coro))

proc wait*(gotask: GoTask[void]): bool =
    while not gotask.coro.finished:
        runOnce()
    if gotask.coro.getState() == CsDead:
        return false
    else:
        return true