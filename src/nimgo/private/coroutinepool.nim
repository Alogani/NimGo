import ../coroutines
import std/math

type
    HistoryLog = object
        ## Helper object to compute discounted max over 400 historic values with minimal cpu time
        ## Complexity time around O(sqrt(n)) where O function is optimized with a sliding window
        data*: array[20, int]
        dataIdx: int
        chunk*: array[20, int]
        chunkIdx: int

    CoroutinePool* = ref object
        ## An object to lend resource
        activeCount: int
        inactives*: seq[Coroutine]
        log*: HistoryLog

proc addVal(log: var HistoryLog, val: int) =
    log.chunkIdx += 1
    if log.chunkIdx == static(len(log.chunk)):
        log.chunkIdx = 0
        log.data[log.dataIdx] = max(log.chunk)
        log.dataIdx += 1
        if log.dataIdx == static(len(log.data)):
            log.dataIdx = 0
    log.chunk[log.chunkIdx] = val

func computeMaxDiscountedVal*(log: HistoryLog): int =
    ## Naive implementation of dynamic sizing estimation
    ## And apply to them a discount when they are old
    const LogDataLen = len(log.data) + 1
    var agregate: array[LogDataLen, int]
    var j: int
    agregate[j] = max(log.chunk[0..log.chunkIdx])
    j += 1
    for i in log.dataIdx..<static(LogDataLen - 1):
        agregate[j] = log.data[i] * (LogDataLen - j) # discount
        j += 1
    for i in 0..<log.dataIdx:
        agregate[j] = log.data[i] * (LogDataLen - j) # discount
        j += 1
    let (q, r) = divmod(max(agregate), LogDataLen)
    if r > 0:
        return q + 1
    else:
        return q

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

var totalRelease*: int
proc releaseCoro*(pool: CoroutinePool, coro: Coroutine) =
    ## double releasing is not checked
    var maxInactives = pool.log.computeMaxDiscountedVal()
    let actualLen = pool.inactives.len()
    pool.activeCount -= 1
    pool.log.addVal(pool.activeCount)
    when defined(debug):
        if pool.totalCount < 0:
            raise newException(ValueError, "Too many coroutines has been released")
    if actualLen < maxInactives:
        pool.inactives.add coro
    elif actualLen == maxInactives:
        totalRelease += 1
    else:
        totalRelease += actualLen + 1 - maxInactives
        pool.inactives.setLen(maxInactives)
    
