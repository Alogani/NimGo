when defined(windows):
  stderr.write("The features of these files hav enot yet been implemented under windows.\n")
  stderr.write("Skipping the test...\n")
  stderr.flushFile()
else:

  import nimgo, nimgo/[coroutines, eventdispatcher]
  import std/unittest


  test "outside coroutine":
    withEventLoop():
      proc coroFn(): int =
        return 42

      check wait(go(coroFn())) == 42


  test "inside coroutine":
    withEventLoop():
      proc innerCoroFn(): int =
        return 42

      proc coroFn() =
        check wait(go(innerCoroFn())) == 42

      go coroFn()

  test "outside coroutine with timeout":
    withEventLoop():
      proc coroFn(): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), 200, true)
        suspend(coro)
        return 42

      check wait(
          go(coroFn()),
          100
        ).isNone()

  test "inside coroutine with timeout":
    withEventLoop():
      proc innerCoroFn(): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), 200, true)
        suspend(coro)
        return 42

      proc coroFn() =
        check wait(go(innerCoroFn()), 100).isNone()

      var task = go coroFn()
      wait(task)
      check task.finished()


  test "inside coroutine with nested timeout":
    proc innerCoroFn(): int =
      var coro = getCurrentCoroutine()
      resumeOnTimer(coro.toOneShot(), 200, true)
      suspend(coro)
      return 42

    proc coroFn() =
      check wait(go(innerCoroFn())) == 42

    check wait(
        go(coroFn()),
        100
      ) == false

  test "inside coroutine waitall - success":
    withEventLoop():
      proc innerCoroFn(): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), 200, true)
        suspend(coro)
        return 42

      proc coroFn() =
        check waitall(
            @[
                go(innerCoroFn()),
                go(innerCoroFn())
          ],
          300) == @[42, 42]

      var task = go coroFn()
      wait(task)
      check task.finished()

  test "inside coroutine waitall - fail":
    withEventLoop():
      proc innerCoroFn(timeoutMs: int): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), timeoutMs, true)
        suspend(coro)
        return 42

      proc coroFn() =
        check waitall(
            @[
                go(innerCoroFn(100)),
                go(innerCoroFn(500))
          ],
          300).len() == 0

      var task = go coroFn()
      wait(task)
      check task.finished()

  test "inside coroutine waitany - fail":
    withEventLoop():
      proc innerCoroFn(timeoutMs: int): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), timeoutMs, true)
        suspend(coro)
        return 42

      proc coroFn() =
        check waitAny(
            @[
                go(innerCoroFn(400)),
                go(innerCoroFn(500))
          ],
          300) == false

      var task = go coroFn()
      wait(task)
      check task.finished()

  test "inside coroutine waitany - success":
    withEventLoop():
      proc innerCoroFn(timeoutMs: int): int =
        var coro = getCurrentCoroutine()
        resumeOnTimer(coro.toOneShot(), timeoutMs, true)
        suspend(coro)
        return 42

      proc coroFn() =
        check waitAny(
            @[
                go(innerCoroFn(100)),
                go(innerCoroFn(500))
          ],
          300)

      var task = go coroFn()
      wait(task)
      check task.finished()
