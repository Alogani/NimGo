import nimgo, nimgo/eventdispatcher
import std/unittest


test "outside coroutine":
    proc coroFn(): int =
        return 42

    check wait(goasync(coroFn())).get() == 42


test "inside coroutine":
    proc innerCoroFn(): int =
        return 42

    proc coroFn() =
        check wait(goasync(innerCoroFn())).get() == 42

    goasync coroFn()

test "outside coroutine with timeout":
    proc coroFn(): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), 200)
        suspend(coro)
        return 42

    check wait(
        goasync(coroFn()),
        100
        ).isNone()

test "inside coroutine with timeout":
    proc innerCoroFn(): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), 200)
        suspend(coro)
        return 42

    proc coroFn() =
        check wait(goasync(innerCoroFn()), 100).isNone()

    check wait(goasync coroFn()) == true


test "inside coroutine with nested timeout":
    proc innerCoroFn(): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), 200)
        suspend(coro)
        return 42

    proc coroFn() =
        check wait(goasync(innerCoroFn())).isSome()

    check wait(
        goasync(coroFn()),
        100
        ) == false

test "inside coroutine waitall - success":
    proc innerCoroFn(): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), 200)
        suspend(coro)
        return 42

    proc coroFn() =
        check waitall(
            @[
                goasync(innerCoroFn()),
                goasync(innerCoroFn())
            ],
            300) == @[42, 42]

    check wait(goasync coroFn()) == true

test "inside coroutine waitall - fail":
    proc innerCoroFn(timeoutMs: int): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), timeoutMs)
        suspend(coro)
        return 42

    proc coroFn() =
        check waitall(
            @[
                goasync(innerCoroFn(100)),
                goasync(innerCoroFn(50000))
            ],
            300).len() == 0

    check wait(goasync coroFn()) == true

test "inside coroutine waitany - fail":
    proc innerCoroFn(timeoutMs: int): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), timeoutMs)
        suspend(coro)
        return 42

    proc coroFn() =
        check waitAny(
            @[
                goasync(innerCoroFn(400)),
                goasync(innerCoroFn(50000))
            ],
            300) == false

    check wait(goasync coroFn()) == true

test "inside coroutine waitany - success":
    proc innerCoroFn(timeoutMs: int): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), timeoutMs)
        suspend(coro)
        return 42

    proc coroFn() =
        check waitAny(
            @[
                goasync(innerCoroFn(100)),
                goasync(innerCoroFn(50000))
            ],
            300)

    check wait(goasync coroFn()) == true