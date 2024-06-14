import nimgo, nimgo/[gofile, gostreams, goproc]

goAndwait proc() =
  var pipe = createGoPipe()
  var p = startProcess(Command(@["sh", "-c", "sleep 1; read a; echo a=$a"]), StreamCapture(pipe.reader), StreamCaptureParent())
  pipe.writer.write("BLAH\n")
  echo "Captured=", p.capturedInput.readAll(500)
  echo "DATA=", p.stdout.readAll(500)
  echo "CODE=", p.waitForExit(closeStdinBefore = false)
