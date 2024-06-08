## Includes some lower level procs, which are useful internally to support cancellation

import ./public/gotasks {.all.}
export gotasks
import ./[coroutines, eventdispatcher]

import std/importutils
privateAccess(GoTaskUntyped)
privateAccess(Callbacks)

proc addCallback*(goTask: GoTaskUntyped, oneShotCoro: OneShotCoroutine) =
    if goTask.finished():
        let coro = oneShotCoro.consumeAndGet()
        if coro != nil:
            resumeLater(coro)
    else:
        gotask.callbacks.list.add oneShotCoro

proc suspendUntilRead*(fd: PollFd, canceller: GoTaskUntyped = nil, consumeEvent: bool): bool =
    let currentCoro = getCurrentCoroutine()
    let currentOneShot = toOneShot(currentCoro)
    if canceller != nil:
        canceller.addCallback(currentOneShot)
    addInsideSelector(fd, currentOneShot, Event.Read)
    suspend(currentCoro)
    if canceller == nil or not canceller.finished():
        if consumeEvent:
            consumeCurrentEvent()
        return true
    return false

proc suspendUntilWrite*(fd: PollFd, canceller: GoTaskUntyped = nil, consumeEvent: bool): bool =
    let currentCoro = getCurrentCoroutine()
    let currentOneShot = toOneShot(currentCoro)
    if canceller != nil:
        canceller.addCallback(currentOneShot)
    addInsideSelector(fd, currentOneShot, Event.Write)
    suspend(currentCoro)
    if canceller == nil or not canceller.finished():
        if consumeEvent:
            consumeCurrentEvent()
        return true
    return false
