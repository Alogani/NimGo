## How could we check for eventual leakage ?

import nimgo/coroutines

import std/unittest

test "One level of coroutine":
    proc entry() =
        raise newException(ValueError, "myerror")

    var coro = newCoroutine(entry)
    try:
        resume(coro)
        check "Uncatch error" == ""
    except CatchableError:
        var err = getCurrentException()
        check err of ValueError
        check err.msg == "myerror"

    try:
        resume(coro)
    except CatchableError:
        var err = getCurrentException()
        check err of CoroutineError


test "Nested coroutines":
    proc nested() =
        raise newException(ValueError, "myerror")

    proc entry() =
        resume(newCoroutine(nested))

    var coro = newCoroutine(entry)
    try:
        resume(coro)
        check "Uncatch error" == ""
    except CatchableError:
        var err = getCurrentException()
        check err of ValueError
        check err.msg == "myerror"
