import aloganimisc/fasttest
import ./coroutines {.all.}

proc coroutineMain() =
    discard 1 + 1

var coro = newCoroutine(coroutineMain)

runBench("Create"):
    let coro = newCoroutine(coroutineMain)
    coro.resume()

runBench("Reinit"):
    coro.reinit(coroutineMain)
    coro.resume()