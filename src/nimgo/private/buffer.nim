import deques

type Buffer* = object
  ## A buffer with no async component
  # Could be implemented with string buffer (faster sometimes)
  # But big penalties on some operations
  searchNLPos: int
  queue: Deque[string]

const DefaultBufferSize* = 1024


proc `=copy`*(dest: var Buffer, src: Buffer) {.error.}

proc newBuffer*(): Buffer =
  Buffer()

proc clear*(self: var Buffer) =
  self.queue.clear()

func empty*(self: Buffer): bool =
  ## More efficient than len
  self.queue.len() == 0

func len*(self: Buffer): int =
  for i in self.queue.items():
    result += i.len()

proc read*(self: var Buffer, outBuffer: var string, count: int) =
  if count <= 0:
    return
  var count = count
  outBuffer = newStringOfCap(min(count, self.len()))
  let lenBefore = self.queue.len()
  while true:
    if self.queue.len() == 0:
      break
    if count > self.queue[0].len():
      var data = self.queue.popFirst()
      outBuffer.add(data)
      count -= data.len()
    elif count == self.queue[0].len():
      outBuffer.add(self.queue.popFirst())
      break
    else:
      var data = move(self.queue[0])
      self.queue[0] = data[count .. ^1]
      data.setLen(count)
      outBuffer.add(move(data))
      break
  self.searchNLPos = max(0, self.searchNLPos - lenBefore + self.queue.len())

proc readLine*(self: var Buffer, outBuffer: var string, keepNewLine = false) =
  ## Don't return if newline not found
  while self.searchNLPos < self.queue.len():
    let index = find(self.queue[self.searchNLPos], '\n')
    if index != -1:
      var len = index + 1
      for i in 0 ..< self.searchNLPos:
        len += self.queue[0].len()
      self.read(outBuffer, len)
      self.searchNLPos = 0
      if not keepNewLine:
        outBuffer.setLen(outBuffer.len() - 1)
      break
    self.searchNLPos += 1

proc readChunk*(self: var Buffer, outBuffer: var string) =
  ## More efficient but unknown size output
  if self.queue.len() > 0:
    outBuffer = self.queue.popFirst()

proc readAll*(self: var Buffer, outBuffer: var string) =
  outBuffer = newStringOfCap(self.len())
  for _ in 0 ..< self.queue.len():
    outBuffer.add(self.queue.popFirst())

proc write*(self: var Buffer, data: sink string) =
  self.queue.addLast(data)
