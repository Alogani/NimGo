import ./eventdispatcher
import ./private/coroutinepool

import std/monotimes, times


setCurrentThreadDispatcher(newDispatcher())
var pollFd = registerHandle(0, {Event.Read})

proc main() =
    echo "before"
    echo suspendUntilRead(pollFd, 500)
    echo "after"
resumeSoon(newCoroutine(main))
runEventLoop()
