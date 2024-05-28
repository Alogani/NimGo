import aloganimisc/fasttest
import nimgo/coroutines

## Tested on Fedora.
## This micro benchmark show a x20 speed improvement of reusage versus creation

proc coroutineMain() =
    discard 1 + 1

var coro = newCoroutine(coroutineMain)

runBench("Create"):
    let coro = newCoroutine(coroutineMain)
    coro.resume()

runBench("Reinit"):
    coro.reinit(coroutineMain)
    coro.resume()