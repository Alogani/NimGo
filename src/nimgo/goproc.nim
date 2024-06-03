import ./[eventdispatcher, gofile]
import ./public/gotasks
when defined(windows):
    import ./private/childproc_win
else:
    import ./private/childproc_posix

import std/[strtabs]

type
    CommandObj* = object
        args*: seq[string]
        workingDir* = ""
        env*: StringTableRef = nil
        name* = "" ## Posix only
        daemon* = false

    GoProcStreamKind = enum
        None, File, Parent, Pipe, Stdout

    GoProcStream = object
        kind: GoProcStreamKind
        file: GoFile

    GoProc* = object
        childproc: Childproc
        stdin*: GoFile
        stdout*: GoFile
        stderr*: GoFile

proc Command*(args: seq[string],
        workingDir = "",
        env: StringTableRef = nil,
        name = "",
        daemon = false): CommandObj =
    CommandObj(
        args: args,
        workingDir: workingDir,
        env: env,
        name: name,
        daemon: daemon
    )


proc StreamNone*(): GoProcStream =
    GoProcStream(kind: None)

proc StreamFile*(f: GoFile): GoProcStream =
    GoProcStream(kind: File, file: f)

proc StreamParent*(): GoProcStream =
    GoProcStream(kind: Parent)

proc StreamPipe*(): GoProcStream =
    ## Won't be subject to filling up (blocking child process), because will be flushed regularly
    GoProcStream(kind: Pipe)

proc StreamStdout*(f: GoFile): GoProcStream =
    ## Only valid for Stderr
    GoProcStream(kind: Stdout)


proc startProcessInPseudoTerminal*(command: CommandObj, mergeStderr = true): tuple[goproc: GoProc, stdin, stdout, stderr: GoFile] =
    discard

proc startProcess*(command: CommandObj; stdin: GoFile = nil, stdout: GoFile = nil, stderr: GoFile = nil): GoProc =
    ## Files won't be closed when process ends
    var childProc = startProcessPosix(command.args[0], command.args[1..^1],
        (
            if stdin == nil:
                FileHandle(-1)
            else:
                stdin.getOsFileHandle()
        ),
        (
            if stdout == nil:
                FileHandle(-1)
            else:
                stdout.getOsFileHandle()
        ),
        (
            if stderr == nil:
                FileHandle(-1)
            else:
                stderr.getOsFileHandle()
        ),
        command.workingDir,
        command.env,
        command.name,
        nil, # preexecFn
        true, # closefds
        @[], # passfds
        startNewSession = (if command.daemon: true else: false),
        umask = (if command.daemon: 0 else: -1)
    )
    return GoProc(childproc: childproc)

proc startProcess*(command: CommandObj; stdin = StreamNone(), stdout = StreamNone(), stderr = StreamNone()): GoProc =
    ## Only StreamPipe will be closed when process ends. They can also be closed by user
    let stdinPipe = (
        case stdin.kind:
        of None:
            (nil, nil)
        of File:
            (stdin.file, nil)
        of Parent:
            (goStdin, nil)
        of Pipe:
            createGoPipe()
        of Stdout:
            raise newException(ValueError, "StreamStdout is only valid for stderr")
    )
    let stdoutPipe = (
        case stdout.kind:
        of None:
            (nil, nil)
        of File:
            (nil, stdout.file)
        of Parent:
            (nil, goStdout)
        of Pipe:
            createGoPipe()
        of Stdout:
            raise newException(ValueError, "StreamStdout is only valid for stderr")
    )
    let stderrPipe = (
        case stderr.kind:
        of None:
            (nil, nil)
        of File:
            (nil, stdout.file)
        of Parent:
            (nil, goStderr)
        of Pipe:
            createGoPipe()
        of Stdout:
            (nil, stdoutPipe[1])
    )
    var goproc = startProcess(command, stdinPipe[0], stdoutPipe[1], stderrPipe[1])
    goproc.stdin = stdinPipe[1]
    goproc.stdout = stdoutPipe[0]
    goproc.stdout = stderrPipe[0]
    return goproc

proc waitForExit*(goproc: var GoProc, timeoutMs = -1, closePipeFirst = false): int =
    ## Child process can deadlock if its standard streams are filled up.
    ## It is important to always call this proc to clean up resources, even if it has been killed
    if closePipeFirst:
        if goproc.stdin != nil and not goproc.stdin.closed(): goproc.stdin.close()
        if goproc.stdout != nil and not goproc.stdout.closed(): goproc.stdout.close()
        if goproc.stderr != nil and not goproc.stderr.closed(): goproc.stderr.close()
    let pollFd = registerProcess(goproc.childproc.getPid())
    if not suspendUntilRead(pollFd, timeoutMs):
        pollFd.unregister()
        return -1
    pollFd.unregister()
    if not closePipeFirst:
        if goproc.stdin != nil and not goproc.stdin.closed(): goproc.stdin.close()
        if goproc.stdout != nil and not goproc.stdout.closed(): goproc.stdout.close()
        if goproc.stderr != nil and not goproc.stderr.closed(): goproc.stderr.close()
    return wait(goproc.childproc)


proc getPid*(p: GoProc): int =
    p.childproc.getPid()

proc running*(p: var GoProc): bool =
    p.childproc.running()

proc suspend*(p: GoProc) =
    p.childproc.suspend()

proc terminate*(p: GoProc) =
    p.childproc.terminate()

proc kill*(p: GoProc) =
    p.childproc.kill()


proc run*(command: CommandObj; stdin = StreamNone(), stdout = StreamNone(), stderr = StreamNone(),
            timeoutMs = -1): tuple[success: bool, exitCode: int; input, output, outputErr: string] =

    var p = startProcess(command, stdinPipe[0], stdoutPipe[1], stderrPipe[1])
    var capturesTasks: seq[GoTask[void]]
    if stdoutPipe[0] != nil:
        capturesTasks.add goAsync(proc() =
            stdoutCapture = stdoutPipe[0].readAll())
    if stderrPipe[0] != nil:
        capturesTasks.add goAsync(proc() =
            stderrCapture = stderrPipe[0].readAll())