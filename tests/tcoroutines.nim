import nimgo/coroutines

import std/unittest

var coro: Coroutine
test "Coroutine - closures":
    coro = newCoroutine(proc() = discard)
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished

test "Coroutine - nimcall":
    proc echoHello() {.nimcall.} = discard
    coro.reinit(echoHello)
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished

test "Coroutine - closures with return val":
    coro.reinit(proc(): string = return "42")
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished
    check getReturnVal[string](coro) == "42"

test "Coroutine - nimcall with return val":
    proc getMagicInt(): int {.nimcall.} = return 42
    coro.reinit(getMagicInt)
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished
    check getReturnVal[int](coro) == 42
