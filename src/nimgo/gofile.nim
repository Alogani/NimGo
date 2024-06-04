when defined(windows):
    include ./private/gofile_win
else:
    include ./private/gofile_posix
import ./private/timeoutwatcher


proc newGoStdin*(): GoFile =
    ## Can only be called once by dispatcher
    newGoFile(stdin.getFileHandle(), fmRead, buffered = false)

proc newGoStdout*(): GoFile =
    ## Can only be called once by dispatcher
    newGoFile(stdout.getFileHandle(), fmWrite, buffered = false)

proc newGoStderr*(): GoFile =
    ## Can only be called once by dispatcher
    newGoFile(stderr.getFileHandle(), fmWrite, buffered = false)


proc endOfFile*(f: Gofile): bool =
    f.state == FsEof

proc closed*(f: Gofile): bool =
    ## Only return true if file was closed using `gofile.close()`.
    ## Closing directly the underlying file or file descriptor won't be detected
    f.state == FsClosed

proc error*(f: Gofile): bool =
    f.state == FsError

proc getError*(f: Gofile): OSErrorCode =
    f.errorCode

proc getOsFileHandle*(f: GoFile): FileHandle =
    FileHandle(f.fd)

proc getSelectorFileHandle*(f: GoFile): PollFd =
    f.pollFd

proc readAvailable*(f: Gofile, size: Positive, timeoutMs = -1, noAsync = false): string =
    if f.buffer != nil:
        if f.buffer.len() < size:
            let data = f.readImpl(max(size, DefaultBufferSize), timeoutMs, noAsync)
            if data != "":
                f.buffer.write(data)
        return f.buffer.read(size)
    else:
        return f.readImpl(size, timeoutMs, noAsync)

proc readChunk*(f: Gofile, timeoutMs = -1, noAsync = false): string =
    ## More efficient, especially when file is buffered
    ## The returned read size is not predictable, but less than `buffer.DefaultBufferSize`
    if f.buffer != nil:
        if f.buffer.empty():
            return f.readImpl(DefaultBufferSize, timeoutMs, noAsync)
        return f.buffer.readChunk()
    else:
        return f.readImpl(DefaultBufferSize, timeoutMs, noAsync)

proc read*(f: Gofile, size: Positive, timeoutMs = -1): string =
    result = newStringOfCap(size)
    var timeout = initTimeOutWatcher(timeoutMs)
    while result.len() < size:
        let data = f.readAvailable(size - result.len(), timeout.getRemainingMs())
        if data.len() == 0:
            break
        result.add(data)

proc readAll*(f: Gofile, timeoutMs = -1): string =
    ## Might return a string even if EOF has not been reached
    var timeout = initTimeOutWatcher(timeoutMs)
    if f.buffer != nil:
        result = f.buffer.readAll()
    while true:
        let data = f.readChunk(timeout.getRemainingMs())
        if data.len() == 0:
            break
        result.add data

proc readLine*(f: GoFile, timeoutMs = -1, keepNewLine = false): string =
    ## Newline is not kept. To distinguish between EOF, you can use `endOfFile`
    var timeout = initTimeOutWatcher(timeoutMs)
    if f.buffer != nil:
        while true:
            let line = f.buffer.readLine(keepNewLine)
            if line.len() != 0:
                return line
            let data = f.readImpl(DefaultBufferSize, timeout.getRemainingMs(), false)
            if data.len() == 0:
                return f.buffer.readAll()
            f.buffer.write(data)
    else:
        const BufSizeLine = 100
        var line = newString(BufSizeLine)
        var length = 0
        while true:
            var c: char
            let readCount = f.readBufferImpl(addr(c), 1, timeout.getRemainingMs(), false)
            if readCount <= 0:
                line.setLen(length)
                return line
            if c == '\c':
                discard f.readBufferImpl(addr(c), 1, timeout.getRemainingMs(), false)
                if keepNewLine:
                    line[length] = '\n'
                    line.setLen(length + 1)
                else:
                    line.setLen(length)
                return line
            if c == '\L':
                if keepNewLine:
                    line[length] = '\n'
                    line.setLen(length + 1)
                else:
                    line.setLen(length)
                return line
            if length == line.len():
                line.setLen(line.len() * 2)
            line[length] = c
            length += 1
