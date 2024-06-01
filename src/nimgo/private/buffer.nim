import deques

type Buffer* = ref object
    ## A buffer with no async component
    # Could be implemented with string buffer (faster sometimes)
    # But big penalties on some operations
    searchNLPos: int
    queue: Deque[string]

const DefaultBufferSize* = 1024

proc newBuffer*(): Buffer =
    Buffer()

proc clear*(self: Buffer) =
    self.queue.clear()

proc empty*(self: Buffer): bool =
    ## More efficient than len
    self.queue.len() == 0

proc len*(self: Buffer): int =
    for i in self.queue.items():
        result += i.len()

proc read*(self: Buffer, count: int): string =
    if count <= 0:
        return
    var count = count
    result = newStringOfCap(min(count, self.len()))
    let lenBefore = self.queue.len()
    while true:
        if self.queue.len() == 0:
            break
        if count > self.queue[0].len():
            result.add(self.queue.popFirst())
            count -= result.len()
        elif count == self.queue[0].len():
            result.add(self.queue.popFirst())
            break
        else:
            var data = move(self.queue[0])
            self.queue[0] = data[count .. ^1]
            data.setLen(count)
            result.add(move(data))
            break
    self.searchNLPos = max(0, self.searchNLPos - lenBefore + self.queue.len())

proc readLine*(self: Buffer, keepNewLine = false): string =
    ## Don't return if newline not found
    while self.searchNLPos < self.queue.len():
        let index = find(self.queue[self.searchNLPos], '\n')
        if index != -1:
            var len = index + 1
            for i in 0 ..< self.searchNLPos:
                len += self.queue[0].len()
            result = self.read(len)
            self.searchNLPos = 0
            if not keepNewLine:
                result.setLen(result.len() - 1)
            break
        self.searchNLPos += 1

proc readChunk*(self: Buffer): string =
    ## More efficient but unknown size output
    if self.queue.len() > 0:
        result = self.queue.popFirst()

proc readAll*(self: Buffer): string =
    result = newStringOfCap(self.len())
    for _ in 0 ..< self.queue.len():
        result.add(self.queue.popFirst())

proc write*(self: Buffer, data: sink string) =
    self.queue.addLast(data)
