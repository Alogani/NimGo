{.warning: "gofile_win is completly untested. Please remove this line, use at your own risk and tell me if it works".}
import std/[winlean, widestrs, oserrors]
from std/syncio import FileHandle, FileMode, FileSeekPos
import ../eventdispatcher
import ./buffer

type
    FileState = enum
        FsOpen, FsClosed, FsEof, FsError

    GoFile* = ref object
        pollFd: PollFd
        fd: Handle
        state: FileState
        errorCode: OSErrorCode
        buffer: Buffer

proc syncioModeToEvent(mode: FileMode): set[Event] =
    case mode:
    of fmRead:
        {Event.Read}
    of fmWrite, fmAppend:
        {Event.Write}
    of fmReadWrite, fmReadWriteExisting:
        {Event.Read, Event.Write}

proc syncioModeToWin(mode: FileMode): tuple[dwDesiredAccess: cint, dwCreationDisposition: cint] =
    case mode:
    of fmRead:
        (GENERIC_READ, OPEN_EXISTING)
    of fmWrite:
        (GENERIC_WRITE, CREATE_ALWAYS)
    of fmReadWrite:
        (GENERIC_ALL, CREATE_ALWAYS)
    of fmReadWriteExisting:
        (GENERIC_ALL, OPEN_ALWAYS)
    of fmAppend: # And we shall move cursor to its end
        (GENERIC_WRITE, OPEN_ALWAYS)

proc close*(f: GoFile) =
    if f.state != FsClosed:
        f.pollFd.unregister()
        if winlean.closeHandle(f.fd) == 0:
            raiseOSError(osLastError())
        f.state = FsClosed

proc getFilePos*(f: GoFile): int32 =
    if setFilePointer(f.fd, 0, addr(result), 1) == 0:
        return -1

proc setFilePos*(f: GoFile; pos: int32; relativeTo: FileSeekPos = fspSet) =
    let seekPos = case relativeTo:
        of fspSet:
            0'i32 #FILE_BEGIN
        of fspCur:
            1'i32 #FILE_CURRENT
        of fspEnd:
            2'i32 #FILE_END
    if setFilePointer(f.fd, pos, nil, seekPos) == 0:
        raiseOSError(osLastError())

proc getFileSize*(f: GoFile): int32 =
    if getFileSize(f.fd, addr(result)) == 0:
        return -1

proc newGoFile*(fd: FileHandle, mode: FileMode, buffered = true): GoFile =
    ## mode is just an indicator for the select pool. Attributes of the handle is not updated
    let events = syncioModeToEvent(mode)
    return GoFile(
        fd: fd,
        pollFd: registerHandle(fd, events),
        state: FsOpen,
        buffer: if buffered: newBuffer() else: nil
    )

proc openGoFile*(filename: string, mode = fmRead, buffered = true): GoFile =
    let winMode = syncioModeToWin(mode)
    let fd = createFileW(
        newWideCString(filename),
        winMode.dwDesiredAccess,
        0, # no sharing
        nil, # lpSecurityAttributes
        winMode.dwCreationDisposition,
        FILE_ATTRIBUTE_NORMAL, # dwFlagsAndAttributes
        0 # hTemplateFile
    )
    if mode == fmAppend:
        if setFilePointer(fd, 0, nil, 2'i32) == 0:
            raiseOSError(osLastError())
    let events = syncioModeToEvent(mode)
    return GoFile(
        fd: fd,
        pollFd: registerHandle(fd, events),
        state: FsOpen,
        buffer: if buffered: newBuffer() else: nil
    )

proc readBufferImpl(f: GoFile, buf: pointer, len: Positive, timeoutMs: int): int {.used.} =
    ## Bypass the buffer
    if not suspendUntilRead(f.pollFd, timeoutMs):
        return -1
    var bytesCount: int32
    if readFile(f.fd, buf, int32(len), addr(bytesCount), nil) == 0:
        f.state = FsError
        f.errorCode = osLastError()
        return -1
    elif bytesCount == 0:
        f.state = FsEof
    return bytesCount

proc readImpl(f: GoFile, len: Positive, timeoutMs: int): string {.used.} =
    ## Bypass the buffer
    result = newStringOfCap(len)
    result.setLen(1)
    let bytesCount = f.readBufferImpl(addr(result[0]), len, timeoutMs)
    if bytesCount <= 0:
        return ""
    result.setLen(bytesCount)

proc write*(f: GoFile, data: sink string, timeoutMs: int): int {.used.} =
    ## Bypass the buffer
    if data.len() == 0:
        return 0
    if not suspendUntilWrite(f.pollFd, timeoutMs):
        return -1
    var bytesCount: int32
    if writeFile(f.fd, addr(data[0]), int32(data.len()), addr(bytesCount), nil) == 0:
        f.state = FsError
        f.errorCode = osLastError()
        return -1
    return bytesCount
