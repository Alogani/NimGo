import std/[bitops, posix, oserrors]
from std/syncio import FileHandle, FileMode, FileSeekPos
import ../eventdispatcher
import ./buffer

type
    FileState = enum
        FsOpen, FsClosed, FsEof, FsError

    GoFile* = ref object
        pollFd = InvalidFd
        fd: cint
        state: FileState
        errorCode: OSErrorCode
        pollable: bool
        buffer: Buffer
        
proc syncioModeToEvent(mode: FileMode): set[Event] =
    case mode:
    of fmRead:
        {Event.Read}
    of fmWrite, fmAppend:
        {Event.Write}
    of fmReadWrite, fmReadWriteExisting:
        {Event.Read, Event.Write}

proc syncioModeToPosix(mode: FileMode): cint =
    case mode:
    of fmRead:
        O_RDONLY
    of fmWrite:
        bitor(O_WRONLY, O_CREAT, O_TRUNC)
    of fmReadWrite:
        bitor(O_RDWR, O_CREAT, O_TRUNC)
    of fmReadWriteExisting:
        O_RDWR
    of fmAppend:
        bitor(O_WRONLY, O_APPEND, O_CREAT)

proc close*(f: GoFile) =
    if f.state != FsClosed and f.pollFd != InvalidFd:
        f.pollFd.unregister()
        if posix.close(f.fd) == -1:
            raiseOSError(osLastError())
        f.state = FsClosed

proc getFilePos*(f: GoFile): int =
    lseek(f.fd, 0, SEEK_CUR)

proc setFilePos*(f: GoFile; pos: int64; relativeTo: FileSeekPos = fspSet) =
    let seekPos = case relativeTo:
        of fspSet:
            SEEK_SET
        of fspCur:
            SEEK_CUR
        of fspEnd:
            SEEK_END
    if lseek(f.fd, pos, seekPos) == -1:
        raiseOSError(osLastError())

proc getFileSize*(f: GoFile): int64 =
    let curPos = getFilePos(f)
    result = lseek(f.fd, 0, SEEK_END)
    setFilePos(f, curPos)

proc isPollable(fd: FileHandle): bool =
    ## EPOLL will throw error on regular file and /dev/null (warning: /dev/null not checked)
    ## Solution: no async on regular file
    var stat: Stat
    discard fstat(fd, stat)
    not S_ISREG(stat.st_mode)

proc newGoFile*(fd: FileHandle, mode: FileMode, buffered = true): GoFile =
    if fcntl(fd, F_SETFL, syncioModeToPosix(mode)) == -1:
        raiseOSError(osLastError())
    let events = syncioModeToEvent(mode)
    let pollable = isPollable(fd)
    return GoFile(
        fd: fd,
        pollFd: if pollable: registerHandle(fd, events) else: PollFd(-1),
        state: FsOpen,
        pollable: pollable,
        buffer: if buffered: newBuffer() else: nil
    )

proc createGoPipe*(buffered = true): tuple[reader, writer: GoFile] =
    var pipesArr: array[2, cint]
    if pipe(pipesArr) != 0:
        raiseOSError(osLastError())
    return (
        newGoFile(pipesArr[0], fmRead, buffered),
        newGoFile(pipesArr[1], fmWrite, buffered),
    )

proc openGoFile*(filename: string, mode = fmRead, buffered = true): GoFile =
    let fd = posix.open(filename, syncioModeToPosix(mode))
    let events = syncioModeToEvent(mode)
    let pollable = isPollable(fd)
    return GoFile(
        fd: fd,
        pollFd: if pollable: registerHandle(fd, events) else: PollFd(-1),
        state: FsOpen,
        pollable: pollable,
        buffer: if buffered: newBuffer() else: nil
    )

proc readBufferImpl(f: GoFile, buf: pointer, size: Positive, timeoutMs: int, noAsync: bool): int {.used.} =
    ## Bypass the buffer
    if f.pollable and not noAsync:
        if not suspendUntilRead(f.pollFd, timeoutMs):
            return -1
    let bytesCount = posix.read(f.fd, buf, size)
    if bytesCount == 0:
        f.state = FsEof
    elif bytesCount == -1:
        f.state = FsError
        f.errorCode = osLastError()
    return bytesCount

proc readImpl(f: GoFile, size: Positive, timeoutMs: int, noAsync: bool): string {.used.} =
    result = newStringOfCap(size)
    result.setLen(1)
    let bytesCount = f.readBufferImpl(addr(result[0]), size, timeoutMs, noAsync)
    if bytesCount <= 0:
        return ""
    result.setLen(bytesCount)

proc write*(f: GoFile, data: sink string, timeoutMs = -1): int {.discardable, used.} =
    ## Bypass the buffer
    if data.len() == 0:
        return 0
    if f.pollable:
        if not suspendUntilWrite(f.pollFd, timeoutMs):
            return -1
    let bytesCount = posix.write(f.fd, addr(data[0]), data.len())
    if bytesCount == -1:
        f.state = FsError
        f.errorCode = osLastError()
    return bytesCount