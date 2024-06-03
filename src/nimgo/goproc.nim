#{.warning: "Currently being implemented".}

import ./[eventdispatcher, gofile, gostreams]
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

    GoProc* = object
        childproc: Childproc
        pollFd: PollFd
        stdin*: GoStream
        stdout*: GoStream
        stderr*: GoStream
        capturesTask: seq[GoTask[void]]

    GoProcStream = ref object of GoBufferStream
        associatedFile: GoFile

    GoProcStreamArg = object
        kind: GoProcStreamKind
        file: GoFile

    GoProcStreamKind = enum
        None, File, Parent, Pipe, Stdout, CapturePipe


#[ *** CommandObj *** ]#

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

#[ *** GoProcStream *** ]#

proc newGoProcStream(file: GoFile): GoProcStream =
    result = GoProcStream(
        associatedFile: file,
    )
    procCall init(GoBufferStream(result))

method close*(s: GoProcStream) =
    procCall close(GoBufferStream(s))
    s.associatedFile.close()


#[ *** GoProcStreamArg *** ]#

proc StreamNone*(): GoProcStreamArg =
    GoProcStreamArg(kind: None)

proc StreamFile*(f: GoFile): GoProcStreamArg =
    GoProcStreamArg(kind: File, file: f)

proc StreamParent*(): GoProcStreamArg =
    GoProcStreamArg(kind: Parent)

proc StreamPipe*(): GoProcStreamArg =
    ## Won't be subject to filling up (blocking child process), because will be flushed regularly
    GoProcStreamArg(kind: Pipe)

proc StreamStdout*(f: GoFile): GoProcStreamArg =
    ## Only valid for Stderr
    GoProcStreamArg(kind: Stdout)

proc StreamCapturePipe*(f: GoFile): GoProcStreamArg =
    ## Only valid for Stderr
    GoProcStreamArg(kind: CapturePipe, file: f)

#[ *** GoProc *** ]#

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
    return GoProc(childproc: childproc, pollFd: registerProcess(childproc.getPid()))

proc startProcess*(command: CommandObj; stdin = StreamNone(), stdout = StreamNone(), stderr = StreamNone()): GoProc =
    ## Only StreamPipe will be closed when process ends. They can also be closed by user
    var capturesTask: seq[GoTask[void]]
    let (stdinChild, stdinParent) = (
        case stdin.kind:
        of None:
            (nil, nil)
        of File:
            (stdin.file, nil)
        of Parent:
            (goStdin, nil)
        of Pipe:
            var pipes = createGoPipe(false)
            (pipes[0], newGoFileStream(pipes[1]))
        of Stdout:
            raise newException(ValueError, "StreamStdout is only valid for stderr")
        else:
            raise newException(ValueError, "")
    )
    let (stdoutChild, stdoutParent) = (
        case stdout.kind:
        of None:
            (nil, nil)
        of File:
            (stdout.file, nil)
        of Parent:
            (goStdout, nil)
        of Pipe:
            var pipes = createGoPipe(false)
            (pipes[1], GoStream(newGoFileStream(pipes[0])))
        of Stdout:
            raise newException(ValueError, "StreamStdout is only valid for stderr")
        of CapturePipe:
            var pipes = createGoPipe(false)
            var captureStream = newGoProcStream(pipes[0])
            let destFile = stdout.file
            capturesTask.add goAsync proc() =
                while true:
                    let data = pipes[0].readChunk()
                    if data == "": break
                    destFile.write(data)
                    captureStream.write(data)
                captureStream.close()
            (pipes[1], GoStream(captureStream))
    )
    let (stderrChild, stderrParent) = (
        case stderr.kind:
        of None:
            (nil, nil)
        of File:
            (stdout.file, nil)
        of Parent:
            (goStdout, nil)
        of Pipe:
            var pipes = createGoPipe(false)
            (pipes[1], GoStream(newGoFileStream(pipes[0])))
        of Stdout:
            (stdoutChild, nil)
        of CapturePipe:
            var pipes = createGoPipe(false)
            var captureStream = newGoProcStream(pipes[0])
            let destFile = stdout.file
            capturesTask.add goAsync proc() =
                while true:
                    let data = pipes[0].readChunk()
                    if data == "": break
                    destFile.write(data)
                    captureStream.write(data)
                captureStream.close()
            (pipes[1], GoStream(captureStream))
    )
    var goproc = startProcess(command, stdinChild, stdoutChild, stderrChild)
    if stdin.kind in { Pipe, CapturePipe }:
        stdinChild.close()
    if stdout.kind in { Pipe, CapturePipe }:
        stdoutChild.close()
    if stderr.kind in { Pipe, CapturePipe }:
        stderrChild.close()
    goproc.stdin = stdinParent
    goproc.stdout = stdoutParent
    goproc.stderr = stderrParent
    goproc.capturesTask = capturesTask
    return goproc

proc waitForExit*(goproc: var GoProc, timeoutMs = -1, closeStdinBefore = true): int =
    ## Child process can deadlock if its standard streams are filled up.
    ## It is important to always call this proc to clean up resources, even if it has been killed
    if closeStdinBefore:
        if goproc.stdin != nil and not goproc.stdin.closed(): goproc.stdin.close()
    if goproc.childproc.running() and not suspendUntilRead(goproc.pollFd, timeoutMs):
        return -1
    goproc.pollFd.unregister()
    if goproc.capturesTask.len() > 0:
        discard waitAll(goproc.capturesTask)
    if not closeStdinBefore:
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

#[
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
]#