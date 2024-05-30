import std/[syncio, oserrors]
import ../eventdispatcher

type
    GoFile* = ref object
        ## Equivalent of an AsyncFile for std/asyncdispatch
        ## The name is different to avoid names conflict
        # For simplicity, all operations are backed by std/syncio for the sync part
        fd: PollFd # PollFd is the same as the file fd
        file: File
        registeredEvents: set[Event]
        pollable: bool

#[ *** Private *** ]#

proc syncioModeToEvent(mode: FileMode): set[Event] =
    case mode:
    of fmRead:
        {Event.Read}
    of fmWrite, fmAppend:
        {Event.Write}
    of fmReadWrite, fmReadWriteExisting:
        {Event.Read, Event.Write}

when defined(linux):
    import std/posix

    proc isPollable(fd: FileHandle): bool =
        ## EPOLL will throw error on regular file and /dev/null (warning: /dev/null not checked)
        ## Solution: no async on regular file
        var stat: Stat
        discard fstat(fd, stat)
        not S_ISREG(stat.st_mode)
else:
     proc isPollable(fd: FileHandle): bool = true

#[ *** Public: alphabetic order *** ]#

proc close*(f: GoFile) =
    f.fd.unregister()
    f.file.close()

proc getFilePos*(f: GoFile): int

proc getFileSize*(f: GoFile): int

proc getOsFileHandle*(f: GoFile): FileHandle =
    FileHandle(f.fd)

proc newGoFile*(fd: FileHandle, mode = fmRead): GoFile =
    var file: File
    if open(file, fd, mode) == false:
        raiseOSError(osLastError())
    let fd = file.getOsFileHandle()
    let events = syncioModeToEvent(mode)
    let pollable = isPollable(fd)
    return GoFile(
        fd: if pollable: registerHandle(fd, events) else: PollFd(fd),
        file: file,
        registeredEvents: events,
        pollable: pollable
    )

proc openGoasync*(filename: string, mode = fmRead, bufsize = -1): GoFile =
    let file = open(filename, mode, bufsize)
    let fd = file.getOsFileHandle()
    let events = syncioModeToEvent(mode)
    let pollable = isPollable(fd)
    return GoFile(
        fd: if pollable: registerHandle(fd, events) else: PollFd(fd),
        file: file,
        registeredEvents: events,
        pollable: pollable
    )

proc read*(f: Gofile, size: int, timeoutMs = -1): Option[string]

proc readAll*(f: Gofile, timeoutMs = -1): Option[string]

proc readBuffer*(f: GoFile, buf: pointer, size: int, timeoutMs = -1): int

proc readLine*(f: GoFile, timeoutMs = -1): Option[string]

proc setFilePos*(f: GoFile, pos: int)

proc setFileSize*(f: GoFile, length: int)

proc write*(f: GoFile, data: string, timeoutMs = -1): int {.discardable}

proc writeBuffer*(f: GoFile, buf: pointer, size: int, timeoutMs = -1): int =
    if f.pollable:
        if Event.Read notin f.registeredEvents:
            updatePollFd(f.fd, {Event.Read})