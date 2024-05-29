import ./private/coroutinepool {.all.}
import ./coroutines
import ./eventdispatcher


proc main() =
    var fd = registerHandle(0, {Event.Read})
    echo "Suspend until stdin"
    suspendUntilRead(fd)
    echo "suspend until timer"
    var coro = getCurrentCoroutine()
    resumeOnTimer(coro, 400)
    coro.suspend()
    echo "waken up"

withEventLoop:
    var coro = newCoroutine(main)
    resumeSoon(coro)
    
echo "done"