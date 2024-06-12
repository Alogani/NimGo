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
        capturedInput*: GoStream
        stdout*: GoStream
        stderr*: GoStream
        captureTasks: seq[GoTask[void]]

    GoProcStream = ref object of GoBufferStream
        associatedFile: GoFile

    GoProcStreamArg = object
        kind: GoProcStreamKind
        file: GoFile

    GoProcStreamKind = enum
        None, File, Parent, Pipe, Stdout, Capture, CaptureParent


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
    GoProcStreamArg(kind: Pipe)

proc StreamStdout*(): GoProcStreamArg =
    ## Only valid for Stderr
    GoProcStreamArg(kind: Stdout)

proc StreamCapture*(f: GoFile): GoProcStreamArg =
    GoProcStreamArg(kind: Capture, file: f)

proc StreamCaptureParent*(): GoProcStreamArg =
    GoProcStreamArg(kind: CaptureParent)


#[ *** GoProc *** ]#

proc startProcess*(command: CommandObj; stdin: GoFile = nil, stdout: GoFile = nil, stderr: GoFile = nil): GoProc =
    ## Files won't be closed when process ends
    when defined(windows):
        raise newException(LibraryError, "Not implemented")
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


proc startProcessInPseudoTerminal*(command: CommandObj, mergeStderr = true): GoProc =
    ## Not available in windows. Some commands with UI will only work weel inside a pseudo terminal
    ## mergeStderr to false will induce pipe creation and indirection, because pseudo terminal has only two file descriptors originally
    ## It can help implements reverse shell.
    when defined(windows):
        raise newException(LibraryError, "This proc is not available under windows")
    else:
        #[
            Flow of data in posix pseudo terminal:
                - writing raw to master -> reading canonical in slave
                - write raw in slave -> reading canonical in master
                - slaves serves as both input and output of child process
                - master serves both to send input/receive output from/to child process
        ]#
        var ptyPairs = newPtyPair()
        var master = newGoProcStream(newGoFile(ptyPairs[0], fmReadWrite))
        var slave = newGoFile(ptyPairs[1], fmRead)
        if mergeStderr:
            result = startProcess(command, slave, slave, slave)
            slave.close()
            result.stdin = master
            result.stdout = master
        else:
            var (stdoutReader, stdoutWriter) = createGoPipe()
            var (stderrReader, stderrWriter) = createGoPipe()
            result = startProcess(command, slave, stdoutWriter, stderrWriter)
            result.stdin = master
            var goprocFd = result.pollFd
            #[
               And then ?
               - we should ensure stdoutWriter+stderrWriter is written to slave before reading master
               - also meaning we can't read from master without having written to slave
               - we should ensure slave will close
               So we need a file stream that induce:
                - when we read master, both stdoutReader and stderrReader are tee to slave
                - when we read stdoutReader/stderrReader, output is tee to master
               Could it really be done without keeping an internal buffer ?
            ]#
            
            


proc startProcess*(command: CommandObj; stdin = StreamNone(), stdout = StreamNone(), stderr = StreamNone()): GoProc =
    ## Only StreamPipe will be closed when process ends. They can also be closed by user
    var goproc: GoProc
    var captureTasks: seq[GoTask[void]]
    var capturedInput: GoStream
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
            (pipes.reader, newGoFileStream(pipes.writer))
        of Stdout:
            raise newException(ValueError, "StreamStdout is only valid for stderr")
        of Capture:
            var pipes = createGoPipe(false)
            capturedInput = newGoProcStream(pipes.writer)
            let providedStdin = stdin.file
            goAsync proc() =
                let goprocFd = goproc.pollFd
                let stdinFd = providedStdin.getSelectorFileHandle()
                while goproc.childproc.running():
                    let wakeUpInfo = suspendUntilAny(@[stdinFd, goprocFd], @[])
                    if wakeUpInfo.pollFd == goprocFd:
                        break
                    consumeCurrentEvent()
                    let data = providedStdin.readChunk(noAsync = true)
                    if data.len() == 0:
                        break
                    pipes.writer.write(data)
                    capturedInput.write(data)
                pipes.writer.close()
                capturedInput.close()
            (pipes.reader, nil)
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
            (pipes.writer, GoStream(newGoFileStream(pipes.reader)))
        of Stdout:
            raise newException(ValueError, "StreamStdout is only valid for stderr")
        of Capture, CaptureParent:
            var pipes = createGoPipe(false)
            var captureStream = newGoProcStream(pipes.reader)
            let destFile = if stdout.kind == CaptureParent: goStdout else: stdout.file
            captureTasks.add goAsync proc() =
                while true:
                    let data = pipes.reader.readChunk()
                    if data == "": break
                    destFile.write(data)
                    captureStream.write(data)
                captureStream.close()
            (pipes.writer, GoStream(captureStream))
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
            (pipes.writer, GoStream(newGoFileStream(pipes.reader)))
        of Stdout:
            (stdoutChild, nil)
        of Capture, CaptureParent:
            var pipes = createGoPipe(false)
            var captureStream = newGoProcStream(pipes.reader)
            let destFile = if stderr.kind == CaptureParent: goStderr else: stderr.file
            captureTasks.add goAsync proc() =
                while true:
                    let data = pipes.reader.readChunk()
                    if data == "": break
                    destFile.write(data)
                    captureStream.write(data)
                captureStream.close()
            (pipes.writer, GoStream(captureStream))
    )
    goproc = startProcess(command, stdinChild, stdoutChild, stderrChild)
    if stdin.kind in { Pipe, Capture, CaptureParent }:
        stdinChild.close()
    if stdout.kind in { Pipe, Capture, CaptureParent }:
        stdoutChild.close()
    if stderr.kind in { Pipe, Capture, CaptureParent }:
        stderrChild.close()
    goproc.stdin = stdinParent
    goproc.stdout = stdoutParent
    goproc.stderr = stderrParent
    goproc.capturedInput = capturedInput
    goproc.captureTasks = captureTasks
    return goproc

proc waitForExit*(goproc: var GoProc, timeoutMs = -1, closeStdinBefore = true): int =
    ## Child process can deadlock if its standard streams are filled up.
    ## It is important to always call this proc to clean up resources, even if it has been killed
    if closeStdinBefore:
        if goproc.stdin != nil and not goproc.stdin.closed(): goproc.stdin.close()
        if goproc.capturedInput != nil and not goproc.capturedInput.closed(): goproc.capturedInput.close()
    if goproc.childproc.running() and not suspendUntilRead(goproc.pollFd, timeoutMs):
        return -1
    goproc.pollFd.unregister()
    if goproc.captureTasks.len() > 0:
        waitAll(goproc.captureTasks)
    if not closeStdinBefore:
        if goproc.stdin != nil and not goproc.stdin.closed(): goproc.stdin.close()
        if goproc.capturedInput != nil and not goproc.capturedInput.closed(): goproc.capturedInput.close()
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