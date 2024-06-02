import ../nimgo
import ./gofile
import ./goproc
import os



var p = startProcess(Command(@["echo", "10000"]), stdout = goStdout)
echo p.waitForExit(2000)