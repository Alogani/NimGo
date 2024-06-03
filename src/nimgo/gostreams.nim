import ./[coroutines, eventdispatcher, gofile]
import ./private/[buffer, timeoutwatcher]
import public/gotasks
import std/deques

type
    GoStream* = ref object of RootRef

    GoBufferStream* = ref object of GoStream
        ## A kind of channel with no thread support
        ## warning..:
        ## Like all channels, there is a risk of deadlock. Deadlock can only happen if read is not done inside a coroutine
        ## If read is done inside a coroutine, the coroutine will simply never resume, leading potentially to a memory leak (handled more or less by ORC)
        buffer: Buffer
        waitersQueue: Deque[OneShotCoroutine]
        wakeupSignal: bool
        closed: bool

    GoFileStream* = ref object of GoStream
        file: GoFile

#[ *** GoStream *** ]#

method close*(s: GoStream) {.base.} = discard
method closed*(s: GoStream): bool {.base.} = discard
method readAvailable*(s: GoStream, size: Positive, timeoutMs = -1): string {.base.} = discard
method readChunk*(s: GoStream, timeoutMs = -1): string {.base.} = discard
    ## Equivalent of readAvailable but with a size optimized for read speed.
    ## The size can vary for each read.
method read*(s: GoStream, size: Positive, timeoutMs = -1): string {.base.} = discard
method readAll*(s: GoStream, timeoutMs = -1): string {.base.} = discard
method readLine*(s: GoStream, timeoutMs = -1, keepNewLine = false): string {.base.} = discard
method write*(s: GoStream, data: sink string, timeoutMs = -1): int {.discardable, base.} = discard


#[ *** GoFileStream *** ]#

proc newGoFileStream*(file: GoFile): GoFileStream =
    GoFileStream(file: file)

method close*(s: GoFileStream) =
    s.file.close()

method closed*(s: GoFileStream): bool =
    s.file.closed()

method readAvailable*(s: GoFileStream, size: Positive, timeoutMs = -1): string =
    readAvailable(s.file, size, timeoutMs)

method readChunk*(s: GoFileStream, timeoutMs = -1): string =
    readChunk(s.file, timeoutMs)

method read*(s: GoFileStream, size: Positive, timeoutMs = -1): string =
    read(s.file, size, timeoutMs)

method readAll*(s: GoFileStream, timeoutMs = -1): string =
    readAll(s.file, timeoutMs)

method readLine*(s: GoFileStream, timeoutMs = -1, keepNewLine = false): string =
    readLine(s.file, timeoutMs, keepNewLine)

method write*(s: GoFileStream, data: sink string, timeoutMs = -1): int {.discardable.} =
    write(s.file, data, timeoutMs)


#[ *** GoBufferStream *** ]#

proc init*(s: GoBufferStream) =
    s.buffer = newBuffer()

proc newGoBufferStream*(): GoBufferStream =
    GoBufferStream(buffer: newBuffer())
    
method close*(s: GoBufferStream) =
    while s.waitersQueue.len() > 0:
        let coro = s.waitersQueue.popFirst()
        resumeSoon(coro.consumeAndGet(false))
    goAsync proc() =
        s.closed = true
        s.wakeupSignal = true

method closed*(s: GoBufferStream): bool =
    s.closed

proc fillBuffer(s: GoBufferStream, timeoutMs: int): bool =
    let timeout = Timeoutwatcher.init(timeoutMs)
    let coro = getCurrentCoroutine()
    if coro == nil:
        s.wakeupSignal = false
        while true:
            runOnce(timeout.getRemainingMs())
            if s.wakeupSignal:
                s.wakeupSignal = false
                return true
            if timeout.expired() or s.closed:
                return false
    else:
        let oneShotCoro = coro.toOneShot()
        s.waitersQueue.addLast oneShotCoro
        if timeoutMs != -1:
            resumeOnTimer(oneShotCoro, timeoutMs)
        suspend(coro)
        if s.closed or oneShotCoro.cancelledByTimer():
            return false
        return true

method readAvailable*(s: GoBufferStream, size: Positive, timeoutMs = -1): string =
    if s.buffer.empty() and not s.closed:
        if not s.fillBuffer(timeoutMs):
            return ""
    s.buffer.read(size)

method readChunk*(s: GoBufferStream, timeoutMs = -1): string =
    if s.buffer.empty() and not s.closed:
        if not s.fillBuffer(timeoutMs):
            return ""
    s.buffer.readChunk()
    
method read*(s: GoBufferStream, size: Positive, timeoutMs = -1): string =
    result = newStringOfCap(size)
    let timeout = TimeOutWatcher.init(timeoutMs)
    while result.len() < size:
        let data = s.readAvailable(size - result.len(), timeout.getRemainingMs())
        if data.len() == 0:
            break
        result.add(data)

method readAll*(s: GoBufferStream, timeoutMs = -1): string =
    let timeout = TimeOutWatcher.init(timeoutMs)
    while true:
        let data = s.readAvailable(DefaultBufferSize, timeout.getRemainingMs())
        if data.len() == 0:
            break
        result.add data
    
method readLine*(s: GoBufferStream, timeoutMs = -1, keepNewLine = false): string =
    let timeout = TimeOutWatcher.init(timeoutMs)
    while true:
        let line = s.buffer.readLine(keepNewLine)
        if line.len() != 0:
            return line
        if not s.fillBuffer(timeout.getRemainingMs()):
            if s.closed:
                return s.buffer.readAll()
            else:
                return ""

method write*(s: GoBufferStream, data: sink string, timeoutMs = -1): int {.discardable.} =
    s.buffer.write(data)
    if s.waitersQueue.len() == 0:
        s.wakeupSignal = true
    else:
        resumeSoon(s.waitersQueue.popFirst().consumeAndGet(false))
