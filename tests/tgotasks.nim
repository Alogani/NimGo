import nimgo, nimgo/[coroutines, eventdispatcher]
import std/unittest


test "outside coroutine":
    withEventLoop():
        proc coroFn(): int =
            return 42

        check wait(goasync(coroFn())) == 42


test "inside coroutine":
    withEventLoop():
        proc innerCoroFn(): int =
            return 42

        proc coroFn() =
            check wait(goasync(innerCoroFn())) == 42

        goasync coroFn()

test "outside coroutine with timeout":
    withEventLoop():
        proc coroFn(): int =
            var coro = getCurrentCoroutine()
            resumeOnTimer(coro.toOneShot(), 200)
            suspend(coro)
            return 42

        check wait(
            goasync(coroFn()),
            sleepTask(100)
            ).isNone()

test "inside coroutine with timeout":
    withEventLoop():
        proc innerCoroFn(): int =
            var coro = getCurrentCoroutine()
            resumeOnTimer(coro.toOneShot(), 200)
            suspend(coro)
            return 42

        proc coroFn() =
            check wait(goasync(innerCoroFn()), sleepTask(100)).isNone()

        var task = goasync coroFn()
        wait(task)
        check task.finished()


test "inside coroutine with nested timeout":
    proc innerCoroFn(): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), 200)
        suspend(coro)
        return 42

    proc coroFn() =
        check wait(goasync(innerCoroFn())) == 42

    check wait(
        goasync(coroFn()),
        sleepTask(100)
        ) == false

test "inside coroutine waitall - success":
    withEventLoop():
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
                sleepTask(300)) == @[42, 42]

        var task = goasync coroFn()
        wait(task)
        check task.finished()

test "inside coroutine waitall - fail":
    withEventLoop():
        proc innerCoroFn(timeoutMs: int): int =
            var coro = getCurrentCoroutine()
            resumeOnTimer(coro.toOneShot(), timeoutMs)
            suspend(coro)
            return 42

        proc coroFn() =
            check waitall(
                @[
                    goasync(innerCoroFn(100)),
                    goasync(innerCoroFn(500))
                ],
                sleepTask(300)).len() == 0

        var task = goasync coroFn()
        wait(task)
        check task.finished()

test "inside coroutine waitany - fail":
    withEventLoop():
        proc innerCoroFn(timeoutMs: int): int =
            var coro = getCurrentCoroutine()
            resumeOnTimer(coro.toOneShot(), timeoutMs)
            suspend(coro)
            return 42

        proc coroFn() =
            check waitAny(
                @[
                    goasync(innerCoroFn(400)),
                    goasync(innerCoroFn(500))
                ],
                sleepTask(300)) == false

        var task = goasync coroFn()
        wait(task)
        check task.finished()

test "inside coroutine waitany - success":
    withEventLoop():
        proc innerCoroFn(timeoutMs: int): int =
            var coro = getCurrentCoroutine()
            resumeOnTimer(coro.toOneShot(), timeoutMs)
            suspend(coro)
            return 42

        proc coroFn() =
            check waitAny(
                @[
                    goasync(innerCoroFn(100)),
                    goasync(innerCoroFn(500))
                ],
                sleepTask(300))

        var task = goasync coroFn()
        wait(task)
        check task.finished()
    