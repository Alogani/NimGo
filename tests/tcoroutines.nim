import nimgo/coroutines

import std/unittest

test "Coroutine - closures":
    var coro = newCoroutine(proc() = discard)
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished

test "Coroutine - nimcall":
    proc echoHello() {.nimcall.} = discard
    var coro = newCoroutine(echoHello)
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished

test "Coroutine - closures with return val":
    var coro = newCoroutine(proc(): string = return "42")
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished
    check getReturnVal[string](coro) == "42"

test "Coroutine - nimcall with return val":
    proc getMagicInt(): int {.nimcall.} = return 42
    var coro = newCoroutine(getMagicInt)
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished
    check getReturnVal[int](coro) == 42
