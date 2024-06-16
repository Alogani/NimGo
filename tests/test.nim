import nimgo, nimgo/[goproc, gofile, gostreams]
import nimgo/private/childproc_posix

#[
goAndWait proc() =
    var p = startProcess(Command(@["sh", "-c", "read a; echo a=$a"]), StreamCapture(goStdin), StreamParent(), StreamParent())
    echo p.waitForExit(closeStdinBefore = false)
]#

template checkNotNil[T](p: T) =
  if p == nil:
    echo "wasnil"

goAndWait proc() =
  #makeParentTerminalRaw()
  var p = startProcessInPseudoTerminal(Command(@["sh", "-c", "read a; echo a=$a"]))
  go proc() =
    while true:
      var data = goStdin.readChunk()
      if p.stdin.closed():
        return
      if data == "": break
      p.stdin.write(data)
  go proc() =
    while true:
      if p.stdout.closed():
        return
      checkNotNil(p.stdout)
      var data = p.stdout.readChunk()
      if data == "": break
      goStdout.write(data)
  echo p.waitForExit(closeStdinBefore = false)

  runEventLoop()