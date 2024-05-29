import aloganimisc/fasttest
import nimgo/coroutines

## Tested on Fedora.
## This micro benchmark shows a x20 speed improvement of reusage versus creation
## The remaining time of reusing coroutines is spent in recreating the context in minicoro.h

proc coroutineMain() =
    discard 1 + 1

runBench("Create"):
    let coro = newCoroutine(coroutineMain)
    coro.resume()

var coro = newCoroutine(coroutineMain)
runBench("Reinit"):
    coro.reinit(coroutineMain)
    coro.resume()
