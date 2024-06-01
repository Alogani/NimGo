when defined(windows):
    include ./gofile_win
else:
    include ./gofile_posix
import ../private/timeoutwatcher


proc endOfFile*(f: Gofile): bool =
    f.state == FsEof

proc closed*(f: Gofile): bool =
    f.state == FsClosed

proc error*(f: Gofile): bool =
    f.state == FsError

proc getError*(f: Gofile): OSErrorCode =
    f.errorCode

proc getOsFileHandle*(f: GoFile): FileHandle =
    FileHandle(f.fd)

proc read*(f: Gofile, len: Positive, timeoutMs = -1): string =
    if f.buffer != nil:
        if f.buffer.len() < len:
            let data = f.readImpl(max(len, DefaultBufferSize), timeoutMs)
            if data != "":
                f.buffer.write(data)
        return f.buffer.read(len)
    else:
        return f.readImpl(len, timeoutMs)

proc readAll*(f: Gofile, timeoutMs = -1): string =
    ## Might return a string even if EOF has not been reached
    let timeout = TimeOutWatcher.init(timeoutMs)
    if f.buffer != nil:
        result = f.buffer.readAll()
    while true:
        let data = f.readImpl(DefaultBufferSize, timeout.getRemainingMs())
        if data.len() == 0:
            break
        result.add data

proc readLine*(f: GoFile, timeoutMs = -1, keepNewLine = false): string =
    ## Newline is not kept. To distinguish between EOF, you can use `endOfFile`
    let timeout = TimeOutWatcher.init(timeoutMs)
    if f.buffer != nil:
        while true:
            let line = f.buffer.readLine(keepNewLine)
            if line.len() != 0:
                return line
            let data = f.readImpl(DefaultBufferSize, timeout.getRemainingMs())
            if data.len() == 0:
                return f.buffer.readAll()
            f.buffer.write(data)
    else:
        const BufSizeLine = 100
        var line = newString(BufSizeLine)
        var length = 0
        while true:
            var c: char
            let readCount = f.readBufferImpl(addr(c), 1, timeout.getRemainingMs())
            if readCount <= 0:
                line.setLen(length)
                return line
            if c == '\c':
                discard f.readBufferImpl(addr(c), 1, timeout.getRemainingMs())
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
