when defined(windows):
    include ./private/gofile_win
else:
    include ./private/gofile_posix
import ./private/timeoutwatcher


var goStdin* {.threadvar.}, goStdout* {.threadvar.}, goStderr* {.threadvar.}: GoFile
goStdin = newGoFile(stdin.getFileHandle(), fmRead, buffered = false)
goStdout = newGoFile(stdout.getFileHandle(), fmWrite, buffered = false)
goStderr = newGoFile(stderr.getFileHandle(), fmWrite, buffered = false)


func endOfFile*(f: Gofile): bool =
    f.state == FsEof

func closed*(f: Gofile): bool =
    ## Only return true if file was closed using `gofile.close()`.
    ## Closing directly the underlying file or file descriptor won't be detected
    f.state == FsClosed

func error*(f: Gofile): bool =
    f.state == FsError

func getError*(f: Gofile): OSErrorCode =
    f.errorCode

func getOsFileHandle*(f: GoFile): FileHandle =
    FileHandle(f.fd)

func getSelectorFileHandle*(f: GoFile): PollFd =
    f.pollFd

proc readAvailable*(f: GoFile, buffer: var string, size: Positive, timeoutMs = -1, noAsync = false) =
    if f.buffered:
        if f.buffer.len() < size:
            let data = f.readImpl(max(size, DefaultBufferSize), timeoutMs, noAsync)
            if data != "":
                f.buffer.write(data)
        f.buffer.read(buffer, size)
    else:
        buffer = f.readImpl(size, timeoutMs, noAsync)

proc readAvailable*(f: GoFile, size: Positive, timeoutMs = -1, noAsync = false): string =
    readAvailable(f, result, size, timeoutMs, noAsync)

proc readChunk*(f: GoFile, buffer: var string, timeoutMs = -1, noAsync = false) =
    ## More efficient, especially when file is buffered
    ## The returned read size is not predictable, but less than `buffer.DefaultBufferSize`
    if f.buffered:
        if f.buffer.empty():
            buffer = f.readImpl(DefaultBufferSize, timeoutMs, noAsync)
            return
        f.buffer.readChunk(buffer)
    else:
        buffer = f.readImpl(DefaultBufferSize, timeoutMs, noAsync)

proc readChunk*(f: GoFile, timeoutMs = -1, noAsync = false): string =
    readChunk(f, result, timeoutMs, noAsync)

proc read*(f: GoFile, buffer: var string, size: Positive, timeoutMs = -1) =
    buffer = newStringOfCap(size)
    var timeout = initTimeOutWatcher(timeoutMs)
    while buffer.len() < size:
        let data = f.readAvailable(size - buffer.len(), timeout.getRemainingMs())
        if data.len() == 0:
            break
        buffer.add(data)

proc read*(f: GoFile, size: Positive, timeoutMs = -1): string =
    read(f, result, size, timeoutMs)

proc readAll*(f: GoFile, buffer: var string, timeoutMs = -1) =
    ## Might return a string even if EOF has not been reached
    var timeout = initTimeOutWatcher(timeoutMs)
    if f.buffered:
        f.buffer.readAll(buffer)
    while true:
        let data = f.readChunk(timeout.getRemainingMs())
        if data.len() == 0:
            break
        buffer.add data

proc readAll*(f: GoFile, timeoutMs = -1): string =
    readAll(f, result, timeoutMs)

proc readLine*(f: GoFile, buffer: var string, timeoutMs = -1, keepNewLine = false) =
    ## Newline is not kept. To distinguish between EOF, you can use `endOfFile`
    var timeout = initTimeOutWatcher(timeoutMs)
    if f.buffered:
        while true:
            var line: string
            f.buffer.readLine(line, keepNewLine)
            if line.len() != 0:
                buffer = line
                return
            let data = f.readImpl(DefaultBufferSize, timeout.getRemainingMs(), false)
            if data.len() == 0:
                f.buffer.readAll(buffer)
                return
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
                buffer = line
                return
            if c == '\c':
                discard f.readBufferImpl(addr(c), 1, timeout.getRemainingMs(), false)
                if keepNewLine:
                    line[length] = '\n'
                    line.setLen(length + 1)
                else:
                    line.setLen(length)
                buffer = line
                return
            if c == '\L':
                if keepNewLine:
                    line[length] = '\n'
                    line.setLen(length + 1)
                else:
                    line.setLen(length)
                buffer = line
                return
            if length == line.len():
                line.setLen(line.len() * 2)
            line[length] = c
            length += 1

proc readLine*(f: GoFile, timeoutMs = -1, keepNewLine = false): string =
    readLine(f, result, timeoutMs, keepNewLine)
