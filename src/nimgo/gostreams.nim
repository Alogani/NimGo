import ./[coroutines, eventdispatcher, gofile, gotaskscomplete]
import ./private/[buffer]
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
method readAvailable*(s: GoStream, size: Positive, canceller: GoTaskUntyped = nil): string {.base.} = discard
method readChunk*(s: GoStream, canceller: GoTaskUntyped = nil): string {.base.} = discard
    ## Equivalent of readAvailable but with a size optimized for read speed.
    ## The size can vary for each read.
method read*(s: GoStream, size: Positive, canceller: GoTaskUntyped = nil): string {.base.} = discard
method readAll*(s: GoStream, canceller: GoTaskUntyped = nil): string {.base.} = discard
method readLine*(s: GoStream, canceller: GoTaskUntyped = nil, keepNewLine = false): string {.base.} = discard
method write*(s: GoStream, data: sink string, canceller: GoTaskUntyped = nil): int {.discardable, base.} = discard


#[ *** GoFileStream *** ]#

proc newGoFileStream*(file: GoFile): GoFileStream =
    GoFileStream(file: file)

method close*(s: GoFileStream) =
    s.file.close()

method closed*(s: GoFileStream): bool =
    s.file.closed()

method readAvailable*(s: GoFileStream, size: Positive, canceller: GoTaskUntyped = nil): string =
    readAvailable(s.file, size, canceller)

method readChunk*(s: GoFileStream, canceller: GoTaskUntyped = nil): string =
    readChunk(s.file, canceller)

method read*(s: GoFileStream, size: Positive, canceller: GoTaskUntyped = nil): string =
    read(s.file, size, canceller)

method readAll*(s: GoFileStream, canceller: GoTaskUntyped = nil): string =
    readAll(s.file, canceller)

method readLine*(s: GoFileStream, canceller: GoTaskUntyped = nil, keepNewLine = false): string =
    readLine(s.file, canceller, keepNewLine)

method write*(s: GoFileStream, data: sink string, canceller: GoTaskUntyped = nil): int {.discardable.} =
    write(s.file, data, canceller)


#[ *** GoBufferStream *** ]#

proc init*(s: GoBufferStream) =
    s.buffer = newBuffer()

proc newGoBufferStream*(): GoBufferStream =
    GoBufferStream(buffer: newBuffer())
    
method close*(s: GoBufferStream) =
    while s.waitersQueue.len() > 0:
        let coro = s.waitersQueue.popFirst()
        resumeSoon(coro.consumeAndGet())
    goAsync proc() =
        s.closed = true
        s.wakeupSignal = true

method closed*(s: GoBufferStream): bool =
    s.closed

proc fillBuffer(s: GoBufferStream, canceller: GoTaskUntyped): bool =
    let coro = getCurrentCoroutineSafe()
    let oneShotCoro = toOneShot(coro)
    if canceller != nil:
        canceller.addCallback(oneShotCoro)
    s.waitersQueue.addLast oneShotCoro
    suspend(coro)
    if canceller != nil:
        return not canceller.finished()
    else:
        return true

method readAvailable*(s: GoBufferStream, size: Positive, canceller: GoTaskUntyped = nil): string =
    if s.buffer.empty() and not s.closed:
        if not s.fillBuffer(canceller):
            return ""
    s.buffer.read(size)

method readChunk*(s: GoBufferStream, canceller: GoTaskUntyped = nil): string =
    if s.buffer.empty() and not s.closed:
        if not s.fillBuffer(canceller):
            return ""
    s.buffer.readChunk()
    
method read*(s: GoBufferStream, size: Positive, canceller: GoTaskUntyped = nil): string =
    result = newStringOfCap(size)
    while result.len() < size:
        let data = s.readAvailable(size - result.len(), canceller)
        if data.len() == 0:
            break
        result.add(data)

method readAll*(s: GoBufferStream, canceller: GoTaskUntyped = nil): string =
    while true:
        let data = s.readAvailable(DefaultBufferSize, canceller)
        if data.len() == 0:
            break
        result.add data
    
method readLine*(s: GoBufferStream, canceller: GoTaskUntyped = nil, keepNewLine = false): string =
    while true:
        let line = s.buffer.readLine(keepNewLine)
        if line.len() != 0:
            return line
        if not s.fillBuffer(canceller):
            if s.closed:
                return s.buffer.readAll()
            else:
                return ""

method write*(s: GoBufferStream, data: sink string, canceller: GoTaskUntyped = nil): int {.discardable.} =
    s.buffer.write(data)
    if s.waitersQueue.len() == 0:
        s.wakeupSignal = true
    else:
        resumeSoon(s.waitersQueue.popFirst().consumeAndGet())
