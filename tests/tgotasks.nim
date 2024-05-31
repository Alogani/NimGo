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
        echo "innerCoroFn resumed"
        return 42

    proc coroFn() =
        check wait(goasync(innerCoroFn())).isNone()
        echo "coroFn resumed"

    check wait(
        goasync(coroFn()),
        100
        ) == false
