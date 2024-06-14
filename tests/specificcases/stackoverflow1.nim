import nimgo/coroutines
import nimgo/private/memallocs

echo "DEEP RECURSION TEST. Expected SIGESEGV+stacktrace"

StackSize = 16 * 1024

proc main(i: int) =
  main(i + 1)

var coro = newCoroutine(proc() = main(0))
resume(coro)