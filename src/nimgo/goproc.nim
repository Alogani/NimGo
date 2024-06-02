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
        None, File, Parent, Capture, CaptureAndTee, Stdout

    GoProcStream = object
        kind: GoProcStreamKind
        file: GoFile

    GoProc* = ref object
        childproc: Childproc

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
    GoProcStream(kind: Capture)

proc StreamTeePipe*(f: GoFile): GoProcStream =
    ## Won't be subject to filling up (blocking child process), because will be flushed regularly
    GoProcStream(kind: CaptureAndTee, file: f)

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

proc waitForExit*(goproc: GoProc, timeoutMs = -1): int =
    ## Child process can deadlock if its standard streams are filled up.
    ## It is important to always call this proc to clean up resources, even if it has been killed
    let pollFd = registerProcess(goproc.childproc.getPid())
    if not suspendUntilRead(pollFd, timeoutMs):
        pollFd.unregister()
        return -1
    pollFd.unregister()
    return wait(goproc.childproc)


proc getPid*(p: GoProc): int =
    p.childproc.getPid()

proc running*(p: GoProc): bool =
    p.childproc.running()

proc suspend*(p: GoProc) =
    p.childproc.suspend()

proc terminate*(p: GoProc) =
    p.childproc.terminate()

proc kill*(p: GoProc) =
    p.childproc.kill()


proc run*(command: CommandObj; stdin = StreamNone(), stdout = StreamNone(), stderr = StreamNone(),
            timeoutMs = -1): tuple[success: bool, exitCode: int; input, output, outputErr: string] =
    let stdinPipe = (
        case stdin.kind:
        of None:
            (nil, nil)
        of File:
            (stdin.file, nil)
        of Parent:
            (goStdin, nil)
        of Capture:
            createGoPipe()
        of Stdout:
            raise newException(ValueError, "StreamStdout is only valid for stderr")
        of CaptureAndTee:
            raise newException(ValueError, "")
    )
    let stdoutPipe = (
        case stdout.kind:
        of None:
            (nil, nil)
        of File:
            (nil, stdout.file)
        of Parent:
            (nil, goStdout)
        of Capture:
            createGoPipe()
        of Stdout:
            raise newException(ValueError, "StreamStdout is only valid for stderr")
        of CaptureAndTee:
            createGoPipe()
    )
    let stderrPipe = (
        case stderr.kind:
        of None:
            (nil, nil)
        of File:
            (nil, stdout.file)
        of Parent:
            (nil, goStderr)
        of Capture:
            createGoPipe()
        of Stdout:
            stdoutPipe
        of CaptureAndTee:
            createGoPipe()
    )
    var stdinCapture, stdoutCapture, stderrCapture: string
    var p = startProcess(command, stdinPipe[0], stdoutPipe[1], stderrPipe[1])
    var capturesTasks: seq[GoTask[void]]
    if stdoutPipe[0] != nil:
        capturesTasks.add goAsync(proc() =
            stdoutCapture = stdoutPipe[0].readAll())
    if stderrPipe[0] != nil:
        capturesTasks.add goAsync(proc() =
            stderrCapture = stderrPipe[0].readAll())