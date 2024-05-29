import ./public/gotasks {.all.}
import ./eventdispatcher
import ./private/coroutinepool

import std/monotimes, times

proc main() =
    echo "in"
    return

withEventLoop():
    var task = goAsync main()
    echo "here"
    let t0 = getMonotime()
    discard task.wait()
    echo "Timetaken=", inMicroseconds(getMonotime() - t0)
    
echo "done"