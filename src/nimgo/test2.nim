import ./eventdispatcher
import ./gofile, ./gostreams
import ./goproc
import ./public/gotasks
import os

var p = startProcess(Command(@["sh", "-c", "sleep 1; read a; echo a=$a"]), StreamPipe(), StreamCaptureParent())
p.stdin.write("BLAH\n")
echo "DATA=", p.stdout.readAll()
echo "CODE=", p.waitForExit()
