import ./eventdispatcher
import ./gofile, ./gostreams
import ./goproc
import ./public/gotasks
import os

var p = startProcess(Command(@["sh", "-c", "sleep 1; echo 45"]), StreamNone(), StreamCapturePipe(goStdout))
sleep(400)
echo "DATA=", p.stdout.readAll()
echo "CODE=", p.waitForExit()

sleep(100_000)