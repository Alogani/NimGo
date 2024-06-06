import aloganimisc/fasttest
import ./eventdispatcher
import ./coroutines
import ./public/gotasks

proc main(val: int): int =
    if val == 1:
        resumeLater(getCurrentCoroutineSafe())
        suspend()
    echo val
    return val


proc main2() =
    echo "before"
    var t = goAsync main(1)
    echo repr waitAll @[goAsync main(2), t, goAsync main(3)]
    echo "after"

withEventLoop():
    goAsync(main2())