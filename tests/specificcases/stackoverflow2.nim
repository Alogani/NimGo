import nimgo/coroutines
import nimgo/private/memallocs

echo "DEEP RECURSION TEST. Expected SIGESEGV without stacktrace"

StackSize = 16 * 1024

proc main(i: int) =
    var bigChunk: array[16 * 1024, int64]
    discard bigChunk

var coro = newCoroutine(proc() = main(0))
resume(coro)