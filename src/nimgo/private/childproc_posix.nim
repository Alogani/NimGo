import std/[posix, os, oserrors]
import std/[strtabs, strutils]

type
    ChildProc* = ref object
        pid: Pid
        exitCode: cint
        hasExited: bool

var PR_SET_PDEATHSIG {.importc, header: "<sys/prctl.h>".}: cint
proc prctl(option, argc2: cint): cint {.varargs, header: "<sys/prctl.h>".}



proc waitImpl(p: var ChildProc; hang: bool) =
    if p.hasExited:
        return
    var status: cint
    let errorCode = waitpid(p.pid, status, if hang: 0 else: WNOHANG)
    if errorCode == p.pid:
        if WIFEXITED(status) or WIFSIGNALED(status):
            p.hasExited = true
            p.exitCode = WEXITSTATUS(status)
    elif errorCode == 0'i32:
        discard ## Assume the process is still up and running
    else:
        raiseOSError(osLastError())

proc wait*(p: var ChildProc): int =
    ## Without it, the pid won't be recycled
    ## Block main thread
    p.waitImpl(true)
    return p.exitCode

proc getPid*(p: ChildProc): int =
    p.pid

proc running*(p: var ChildProc): bool =
    p.waitImpl(false)
    return not p.hasExited

proc suspend*(p: ChildProc) =
    if posix.kill(p.pid, SIGSTOP) != 0'i32: raiseOSError(osLastError())

proc resume*(p: ChildProc) =
    if posix.kill(p.pid, SIGCONT) != 0'i32: raiseOSError(osLastError())

proc terminate*(p: ChildProc) =
    if posix.kill(p.pid, SIGTERM) != 0'i32: raiseOSError(osLastError())

proc kill*(p: ChildProc) =
    if posix.kill(p.pid, SIGKILL) != 0'i32: raiseOSError(osLastError())

proc envToCStringArray(t: StringTableRef): cstringArray =
    ## from std/osproc
    if t == nil:
        return nil
    result = cast[cstringArray](alloc0((t.len + 1) * sizeof(cstring)))
    var i = 0
    for key, val in pairs(t):
        var x = key & "=" & val
        result[i] = cast[cstring](alloc(x.len+1))
        copyMem(result[i], addr(x[0]), x.len+1)
        inc(i)

proc readAll(fd: FileHandle): string =
    let bufferSize = 1024
    result = newString(bufferSize)
    var totalCount: int
    while true:
        let bytesCount = posix.read(fd, addr(result[totalCount]), bufferSize)
        if bytesCount == 0:
            break
        totalCount += bytesCount
        result.setLen(totalCount + bufferSize)
    result.setLen(totalCount)

proc startProcessPosix*(command: string, args: seq[string],
            stdin = FileHandle(-1), stdout = FileHandle(-1), stderr = FileHandle(-1);
            cwd = "", env: StringTableRef = nil;
            name = ""; prexecFn: proc() = nil, closeFds = true,
            passFds: seq[(FileHandle, FileHandle)] = @[],
            startNewSession = false, umask = -1
        ): ChildProc =
    ## Uses fork/exec. Inspired by python Popen API for arguments
    ## startNewSession + umask = 0 is equivalent to spawning a deamon
    var passFdsWithStdHandles = passFds
    if stdin != FileHandle(-1):
        passFdsWithStdHandles.add (stdin, FileHandle(STDIN_FILENO))
    if stdout != FileHandle(-1):
        passFdsWithStdHandles.add (stdout, FileHandle(STDOUT_FILENO))
    if stderr != FileHandle(-1):
        passFdsWithStdHandles.add (stderr, FileHandle(STDERR_FILENO))
    var fdstoKeep = newSeqOfCap[FileHandle](passFdsWithStdHandles.len())
    for i in 0..high(passFdsWithStdHandles):
        fdstoKeep.add passFdsWithStdHandles[i][1]
    # Nim objects to C objects
    var sysArgs = allocCStringArray(
        (if name != "": @[name] else: @[command]) &
        args)
    defer: deallocCStringArray(sysArgs)
    var sysEnv = envToCStringArray(env)
    defer: (if sysEnv != nil: deallocCStringArray(sysEnv))
    # Error pipe for catching inside child
    var errorPipes: array[2, cint]
    if pipe(errorPipes) != 0'i32:
        raiseOSError(osLastError())
    let ppidBeforeFork = getCurrentProcessId()
    let pid = fork()
    if pid == 0'i32: # Child
        try:
            var childPid = getCurrentProcessId()
            # Working dir
            if cwd.len > 0'i32:
                setCurrentDir(cwd)
            # IO handling
            for (src, dest) in passFdsWithStdHandles:
                if src != dest:
                    let exitCode = dup2(src, dest)
                    if exitCode < 0'i32: raiseOSError(osLastError())
            if closeFds:
                for (_, file) in walkDir("/proc/" & $childPid & "/fd/",
                        relative = true):
                    let fd = file.parseInt().cint
                    if fd notin fdstoKeep and fd != errorPipes[1]:
                        discard close(fd)
            if startNewSession:
                if setsid() < 0'i32: raiseOSError(osLastError())
                signal(SIGHUP, SIG_IGN)
            else:
                let exitCode = prctl(PR_SET_PDEATHSIG, SIGHUP)
                if exitCode < 0'i32 or getppid() != ppidBeforeFork:
                    exitnow(1)
            if umask != -1:
                discard umask(Mode(umask))
            if prexecFn != nil:
                prexecFn()
            discard close(errorPipes[1])
        except:
            let errMsg = getCurrentExceptionMsg()
            discard write(errorPipes[1], addr(errMsg[0]), errMsg.len())
            discard close(errorPipes[1]) # Could have been using fnctl FD_CLOEXEC
            exitnow(1)
            # Should be safe (or too hard to catch) from here
            # Exec
        when defined(uClibc) or defined(linux) or defined(haiku):
            let exe = findExe(command)
            if sysEnv != nil:
                discard execve(exe.cstring, sysArgs, sysEnv)
            else:
                discard execv(exe.cstring, sysArgs)
        else: # MacOs mainly
            if sysEnv != nil:
                var environ {.importc.}: cstringArray
                environ = sysEnv
            discard execvp(command.cstring, sysArgs)
        exitnow(1)

    # Child error handling
    if pid < 0: raiseOSError(osLastError())
    discard close(errorPipes[1])
    var errorMsg = readAll(errorPipes[0])
    discard close(errorPipes[0])
    if errorMsg.len() != 0: raise newException(OSError, errorMsg)
    return ChildProc(pid: pid, hasExited: false)
