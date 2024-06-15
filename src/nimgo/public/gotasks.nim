import ../[coroutines, eventdispatcher]
import ../private/timeoutwatcher
import std/[options, macros]

export options


type
  Callbacks = ref object
    list: seq[OneShotCoroutine]

  GoTaskObj = object of RootObj
    coro: Coroutine
    callbacks: Callbacks

  GoTaskUntyped* = ref GoTaskObj
  GoTask*[T] = GoTaskUntyped


proc goImpl(callbacks: Callbacks, fn: proc()): GoTask[void] =
  var coro = newCoroutine(fn)
  resumeLater(coro)
  return GoTask[void](coro: coro, callbacks: callbacks)

proc goImpl[T](callbacks: Callbacks, fn: proc(): T): GoTask[T] =
  var coro = newCoroutine(fn)
  resumeLater(coro)
  return GoTask[T](coro: coro, callbacks: callbacks)

macro go*(fn: typed): untyped =
  if fn.kind == nnkCall:
    let fnType = getType(fn)
    let closureSym = genSym(nskProc)
    if fnType.strVal() == "void":
      return quote do:
        proc `closureSym`(): GoTask[void] {.discardable.} =
          let callbacks = Callbacks()
          result = goImpl(
            callbacks,
            proc() =
              `fn`
              for cb in callbacks.list:
                let coro = cb.consumeAndGet()
                if coro != nil:
                  resumeLater(coro)
          )
        `closureSym`()
    else:
      return quote do:
        proc `closureSym`(): GoTask[`fnType`] =
          let callbacks = Callbacks()
          result = goImpl(
            callbacks,
            proc(): `fnType` =
              result = `fn`
              for cb in callbacks.list:
                let coro = cb.consumeAndGet()
                if coro != nil:
                  resumeLater(coro)
          )
        `closureSym`()
  let symType = getType(fn)
  let declarationVal = symType[0].strVal()
  if declarationVal != "proc" and declarationVal != "func":
    error("Expected a function or a call")
  let fnType = symType[1]
  let closureSym = genSym(nskProc)
  if fnType.strVal() == "void":
    return quote do:
      proc `closureSym`(): GoTask[void] {.discardable.} =
        let callbacks = Callbacks()
        result = goImpl(
          callbacks,
          proc() =
            `fn`()
            for cb in callbacks.list:
              let coro = cb.consumeAndGet()
              if coro != nil:
                resumeLater(coro)
        )
      `closureSym`()
  else:
    return quote do:
      proc `closureSym`(): GoTask[`fnType`] =
        let callbacks = Callbacks()
        result = goImpl(
          callbacks,
          proc(): `fnType` =
            result = `fn`()
            for cb in callbacks.list:
              let coro = cb.consumeAndGet()
              if coro != nil:
                resumeLater(coro)
        )
      `closureSym`()


proc finished*(gotask: GoTaskUntyped): bool =
  gotask.coro.finished()

proc finished*[T](gotask: GoTask[T]): bool =
  gotask.coro.finished()

proc waitImpl[T](currentCoro: Coroutine, gotask: GoTask[T], timeoutMs: int): bool =
  if currentCoro == nil:
    if timeoutMs == -1:
      while not gotask.finished():
        runOnce()
      return true
    elif timeoutMs == 0:
      runOnce()
      return gotask.finished()
    else:
      var timeout = initTimeoutWatcher(timeoutMs)
      while not timeout.expired():
        runOnce()
        if gotask.finished():
          return true
      return false
  else:
    let sleeper = toOneShot(currentCoro)
    gotask.callbacks.list.add(sleeper)
    if timeoutMs == -1:
      suspend(currentCoro)
      return true
    elif timeoutMs == 0:
      resumeAfterLoop(sleeper)
      suspend(currentCoro)
      return gotask.finished()
    else:
      resumeOnTimer(sleeper, timeoutMs, false)
      suspend(currentCoro)
      return gotask.finished()

proc waitAnyImpl(currentCoro: Coroutine, gotasks: seq[GoTaskUntyped], timeoutMs: int): bool =
  ## Avoid the worst case complexity of O(n x t), but instead O(2n)
  let sleeper = toOneShot(currentCoro) # Will work even if currentCoro is nil
  for task in gotasks:
    if task.finished():
      discard sleeper.consumeAndGet()
      return
    task.callbacks.list.add(sleeper)
  if currentCoro == nil:
    if timeoutMs == -1:
      while not sleeper.hasBeenResumed():
        runOnce()
    elif timeoutMs == 0:
      runOnce()
      return sleeper.hasBeenResumed()
    else:
      var timeout = initTimeoutWatcher(timeoutMs)
      while not timeout.expired():
        runOnce()
        if  sleeper.hasBeenResumed():
          return true
      return false
  else:
    if timeoutMs == -1:
      suspend()
      return true
    elif timeoutMs == 0:
      resumeAfterLoop(sleeper)
      suspend(currentCoro)
      # Certainly possible to avoid again this loop, but this would break encapsulation
      for task in gotasks:
        if task.finished():
          return true
      return false
    else:
      resumeOnTimer(sleeper, timeoutMs, false)
      suspend(currentCoro)
      for task in gotasks:
        if task.finished():
          return true
      return false

proc wait*[T](gotask: GoTask[T], timeoutMs: Natural): Option[T] =
  if not waitImpl(getCurrentCoroutine(), gotask, timeoutMs):
    return none(T)
  else:
    return some(getReturnVal[T](gotask.coro))

proc wait*[T](gotask: GoTask[T]): T =
  discard waitImpl(getCurrentCoroutine(), gotask, -1)
  return getReturnVal[T](gotask.coro)

proc wait*(gotask: GoTask[void], timeoutMs: Natural): bool =
  return waitImpl(getCurrentCoroutine(), gotask, timeoutMs)

proc wait*(gotask: GoTask[void]) =
  discard waitImpl(getCurrentCoroutine(), gotask, -1)

proc waitAllImpl[T](gotasks: seq[GoTask[T]], timeoutMs: int): bool =
  let currentCoro = getCurrentCoroutine()
  if timeoutMs == -1:
    for task in gotasks:
      if not task.finished():
        discard waitImpl(currentCoro, task, -1)
  else:
    var timeout = initTimeoutWatcher(timeoutMs)
    for task in gotasks:
      if not task.finished():
        if not waitImpl(currentCoro, task, timeout.getRemainingMs()):
          return false
  return true

proc waitAll*[T](gotasks: seq[GoTask[T]], timeoutMs = -1): seq[T] =
  if not waitAllImpl(gotasks, timeoutMs):
    return
  result = newSeqOfCap[T](gotasks.len())
  for task in gotasks:
    result.add getReturnVal[T](task.coro)

proc waitAll*(gotasks: seq[GoTask[void]], timeoutMs: Natural): bool =
  return waitAllImpl(gotasks, timeoutMs)

proc waitAll*(gotasks: seq[GoTask[void]]) =
  discard waitAllImpl(gotasks, -1)

proc waitAny*[T](gotasks: seq[GoTask[T]], timeoutMs: Natural): bool =
  return waitAnyImpl(getCurrentCoroutine(), gotasks, timeoutMs)

proc waitAny*[T](gotasks: seq[GoTask[T]]) =
  waitAnyImpl(getCurrentCoroutine(), gotasks, -1)

template goAndwait*(fn: untyped): untyped =
  ## Shortcut for `wait(go fn)`
  wait(go(`fn`))

template goAndwait*(fn: untyped, timeoutMs: Natural): untyped =
  ## Shortcut for `wait(go fn)`
  wait(go(`fn`), timeoutMs)

proc addCallback*(goTask: GoTaskUntyped, oneShotCoro: OneShotCoroutine) =
  if goTask.finished():
    let coro = oneShotCoro.consumeAndGet()
    if coro != nil:
      resumeLater(coro)
  else:
    gotask.callbacks.list.add oneShotCoro

proc resumeAfter*(goTask: GoTaskUntyped) =
  var coro = getCurrentCoroutineSafe()
  addCallback(goTask, toOneShot(coro))
  suspend(coro)
