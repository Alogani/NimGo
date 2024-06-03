import ./eventdispatcher
import ./gofile, ./gostreams
import ./goproc
import ./public/gotasks
import os
import std/posix

var p = createGoPipe(false)
goasync proc() =
    sleepAsync(1000)
    p.reader.close()
echo "count=", p.writer.write("blah")
echo p.reader.read(5)