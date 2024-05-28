import aloganimisc/fasttest

#[
    Tested on commit number 49, with Fedora OS

    This benchmarks serves two purposes:
    - Demonstrating the deep of the coro stacksize (16 000 recursions with no stack variable)
    - Testing the speed of coroutine suspend/resume compared to a select poll
    Coroutine switch is 9 times quicker than a select, independently of the stack size
]#

import nimgo/coroutines
import std/selectors

const Rep = 1000

var Glob: int
proc suspendForever() =
    while true:
        Glob.inc()
        suspend()
proc growStack(i: int) =
    while i < 16000:
        growStack(i + 1)
    suspendForever()
let coro = newCoroutine(proc() = growStack(0))
runBench("context switch"):
    for i in 0..<Rep:
        coro.resume()
echo Glob

const Fd = 1
let selector = newSelector[int]()
selector.registerHandle(Fd, {Event.Write}, 0)
var found: bool
runBench("selector poll"):
    for i in 0..<Rep:
        let readyKeys = selector.select(0)
        for key in readyKeys:
            if key.fd == Fd:
                found = true
echo found