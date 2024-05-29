import ../coroutines
import std/math

type
    HistoryLog = object
        ## Helper object to compute discounted max over a period of time in a dynamic way
        data: array[20, int]
        dataIdx: int
        averageMax: int
        recentMax: int
        elapsedCycles: int

    CoroutinePool* = ref object
        ## An object to lend resource
        activeCount: int
        inactives: seq[Coroutine]
        log*: HistoryLog

func computeAverageMax(log: var HistoryLog): int =
    const LogDataLen = len(log.data)
    var total: int
    var j = 1 # The first value is also discounted, because it is not as recent as log.recentMax
    for i in countdown(log.dataIdx, 0):
        total = max(total, log.data[i] * (LogDataLen * 3 div 2 - j)) # discount
        j += 1
    for i in countdown(static(LogDataLen - 1), log.dataIdx + 1):
        total = max(total, log.data[i] * (LogDataLen * 3 div 2 - j)) # discount
        j += 1
    return ceilDiv(total, LogDataLen * 3 div 2)

proc addVal(log: var HistoryLog, val: int) =
    log.elapsedCycles += 1
    if log.elapsedCycles < max(10, log.averageMax div 8):
        if val > log.recentMax:
            log.recentMax = val
        return
    log.elapsedCycles = 0
    log.dataIdx += 1
    if log.dataIdx == static(len(log.data)):
        log.dataIdx = 0
    log.data[log.dataIdx] = log.recentMax
    log.recentMax = val
    log.averageMax = log.computeAverageMax()

func getAverageMax(log: HistoryLog): int =
    max(log.recentMax, log.averageMax) * 12 div 10


proc acquireCoroutineImpl[T](pool: CoroutinePool, entryFn: EntryFn[T]): Coroutine =
    pool.activeCount += 1
    pool.log.addVal(pool.activeCount)
    if pool.inactives.len() == 0:
        result = newCoroutine(entryFn)
    else:
        result = pool.inactives.pop()
        reinit(result, entryFn)

proc acquireCoro*[T](pool: CoroutinePool, entryFn: EntryFn[T]): Coroutine =
    acquireCoroutineImpl[T](pool, entryFn)

proc acquireCoro*(pool: CoroutinePool, entryFn: EntryFn[void]): Coroutine =
    ## release should be called afterward to avoid memory leaks
    acquireCoroutineImpl[void](pool, entryFn)

proc releaseCoro*(pool: CoroutinePool, coro: Coroutine) =
    ## double releasing is not checked
    var maxInactives = pool.log.getAverageMax() - pool.activeCount
    let actualLen = pool.inactives.len()
    pool.activeCount -= 1
    pool.log.addVal(pool.activeCount)
    when defined(debug):
        if pool.totalCount < 0:
            raise newException(ValueError, "Too many coroutines has been released")
    if actualLen < maxInactives:
        pool.inactives.add coro
    elif actualLen == maxInactives:
        discard
    else:
        pool.inactives.setLen(maxInactives)
    