## goproc definition of usage

## dd - readfile
# Example 1
var p = startProcess(Command(@["dd", "if=myfile"]), stdout = StreamPipe())
var data = p.stdout.readAll()
p.waitForExit()

# Example 2
var res = run(Command(@["dd", "if=myfile"]), stdout = StreamPipe())
var data = res.output

# Example 3
var res = goasync run(Command(@["dd", "if=myfile"]), stdout = StreamPipe())
var data = wait res.output

# Example 4
var res = wait goasync(proc(): string =
  var res = run(Command(@["dd", "if=myfile"]), stdout = StreamPipe())
  return res.output
)


## dd - writefile
# Example 1
var p = startProcess(Command(@["dd", "of=myfile"]), stdin = StreamPipe())
p.stdin.write("mydata")
p.waitForExit()

# Example 2
var res = run(Command(@["dd", "of=myfile"]), stdin = StreamData("mydata"))


## UI
# Example 1
var res = run(Command(@["passswd", "myuser"]), allStreams = StreamParent())

# Example 2
var res = run(Command(@["passswd", "myuser"]), allStreams = StreamCaptureParent())
#Equivalent to var res = run(Command(@["passswd", "myuser"]), stdin = StreamCapture(goStdin), stdout = StreamCapture(goStdout))
echo res.input
echo res.output