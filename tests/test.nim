import nimgo, nimgo/[goproc, gofile]

goAndWait proc() =
    var p = startProcess(Command(@["sh", "-c", "read a; echo a=$a"]), StreamCapture(goStdin), StreamParent(), StreamParent())
    sleepAsync(10000)
    echo p.waitForExit()