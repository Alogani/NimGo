import ./[coroutines, eventdispatcher, gofile]
import ./private/[buffer, timeoutwatcher]
import public/gotasks
import std/deques

type
  GoStream* = ref object of RootRef

  GoBufferStream* = ref object of GoStream
    ## A kind of channel with no thread support and no size limit
    ## warning..:
    ##   Like all channels, there is a risk of deadlock. Deadlock can only happen if read is not done inside a coroutine
    ##   If read is done inside a coroutine, the coroutine will simply never resume, leading potentially to a memory leak (handled more or less by ORC)
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
method readAvailable*(s: GoStream, buffer: var string, size: Positive, timeoutMs = -1) {.base.} = discard
method readChunk*(s: GoStream, timeoutMs = -1): string {.base.} = discard
method readChunk*(s: GoStream, buffer: var string, timeoutMs = -1) {.base.} = discard
  ## Equivalent of readAvailable but with a size optimized for read speed.
  ## The size can vary for each read.
method read*(s: GoStream, size: Positive, timeoutMs = -1): string {.base.} = discard
method read*(s: GoStream, buffer: var string, size: Positive, timeoutMs = -1) {.base.} = discard
method readAll*(s: GoStream, timeoutMs = -1): string {.base.} = discard
method readAll*(s: GoStream, buffer: var string, timeoutMs = -1) {.base.} = discard
method readLine*(s: GoStream, timeoutMs = -1, keepNewLine = false): string {.base.} = discard
method readLine*(s: GoStream, buffer: var string, timeoutMs = -1, keepNewLine = false) {.base.} = discard
method write*(s: GoStream, data: sink string, timeoutMs = -1): int {.discardable, base.} = discard


#[ *** GoFileStream *** ]#

proc newGoFileStream*(file: GoFile): GoFileStream =
  GoFileStream(file: file)

method close*(s: GoFileStream) =
  s.file.close()

method closed*(s: GoFileStream): bool =
  s.file.closed()

method readAvailable*(s: GoFileStream, size: Positive, timeoutMs = -1): string =
  readAvailable(s.file, result, size, timeoutMs)

method readAvailable*(s: GoFileStream, buffer: var string, size: Positive, timeoutMs = -1) =
  readAvailable(s.file, buffer, size, timeoutMs)

method readChunk*(s: GoFileStream, timeoutMs = -1): string =
  readChunk(s.file, result, timeoutMs)

method readChunk*(s: GoFileStream, buffer: var string, timeoutMs = -1) =
  readChunk(s.file, buffer, timeoutMs)

method read*(s: GoFileStream, size: Positive, timeoutMs = -1): string =
  read(s.file, result, size, timeoutMs)

method read*(s: GoFileStream, buffer: var string, size: Positive, timeoutMs = -1) =
  read(s.file, buffer, size, timeoutMs)

method readAll*(s: GoFileStream, timeoutMs = -1): string =
  readAll(s.file, result, timeoutMs)

method readAll*(s: GoFileStream, buffer: var string, timeoutMs = -1) =
  readAll(s.file, buffer, timeoutMs)

method readLine*(s: GoFileStream, timeoutMs = -1, keepNewLine = false): string =
  readLine(s.file, result, timeoutMs, keepNewLine)

method readLine*(s: GoFileStream, buffer: var string, timeoutMs = -1, keepNewLine = false) =
  readLine(s.file, buffer, timeoutMs, keepNewLine)

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
    resumeSoon(coro.consumeAndGet())
  go proc() =
    s.closed = true
    s.wakeupSignal = true

method closed*(s: GoBufferStream): bool =
  s.closed

proc fillBuffer(s: GoBufferStream, timeoutMs: int): bool =
  if not s.buffer.empty():
    return true
  if s.closed:
    return false
  let coro = getCurrentCoroutineSafe()
  let oneShotCoro = toOneShot(coro)
  s.waitersQueue.addLast oneShotCoro
  if timeoutMs == 0:
    resumeAfterLoop(oneShotCoro)
  elif timeoutMs != -1:
    resumeOnTimer(oneShotCoro, timeoutMs, false)
  suspend(coro)
  return not s.buffer.empty()

method readAvailable*(s: GoBufferStream, buffer: var string, size: Positive, timeoutMs = -1) =
  if not s.fillBuffer(timeoutMs):
    wasMoved(buffer)
    return
  s.buffer.read(buffer, size)

method readAvailable*(s: GoBufferStream, size: Positive, timeoutMs = -1): string =
  readAvailable(s, result, size, timeoutMs)

method readChunk*(s: GoBufferStream, buffer: var string, timeoutMs = -1) =
  if not s.fillBuffer(timeoutMs):
    wasMoved(buffer)
    return
  s.buffer.readChunk(buffer)

method readChunk*(s: GoBufferStream, timeoutMs = -1): string =
  readChunk(s, result, timeoutMs)
  
method read*(s: GoBufferStream, buffer: var string, size: Positive, timeoutMs = -1) =
  buffer = newStringOfCap(size)
  var timeout = initTimeOutWatcher(timeoutMs)
  while buffer.len() < size:
    let data = s.readAvailable(size - buffer.len(), timeout.getRemainingMs())
    if data.len() == 0:
      break
    buffer.add(data)

method read*(s: GoBufferStream, size: Positive, timeoutMs = -1): string =
  read(s, result, size, timeoutMs)

method readAll*(s: GoBufferStream, buffer: var string, timeoutMs = -1) =
  var timeout = initTimeOutWatcher(timeoutMs)
  wasMoved(buffer)
  while true:
    let data = s.readAvailable(DefaultBufferSize, timeout.getRemainingMs())
    if data.len() == 0:
      break
    buffer.add data

method readAll*(s: GoBufferStream, timeoutMs = -1): string =
  readAll(s, result, timeoutMs)
  
method readLine*(s: GoBufferStream, buffer: var string, timeoutMs = -1, keepNewLine = false) =
  var timeout = initTimeOutWatcher(timeoutMs)
  wasMoved(buffer)
  while true:
    var line: string
    s.buffer.readLine(line, keepNewLine)
    if line.len() != 0:
      buffer = line
      return
    if not s.fillBuffer(timeout.getRemainingMs()):
      if s.closed:
        s.buffer.readAll(buffer)
        return
      else:
        return

method readLine*(s: GoBufferStream, timeoutMs = -1, keepNewLine = false): string =
  readLine(s, result, timeoutMs, keepNewLine)

method write*(s: GoBufferStream, data: sink string, timeoutMs = -1): int {.discardable.} =
  ## Timeout parameter exists for compatibility reason, but because GoBufferStream has not a limited size, it use usless
  s.buffer.write(data)
  if s.waitersQueue.len() == 0:
    s.wakeupSignal = true
  else:
    resumeSoon(s.waitersQueue.popFirst().consumeAndGet())
  