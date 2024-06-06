# NimGo

_NimGo: Asynchronous Library Inspired by Go's Asyncio. Or for Purists: Stackful Coroutines library associated with an I/O Pollable Event Loop and Dispatcher_

This repository is currently an alpha release. You can expect bugs and inefficiencies. Do not use in production !

## Goal
Provide a simple, concise and efficient library for I/O.

No async/await, no pragma, no Future[T] everywhere !

Only one word to remember : **goAsync** (and optionaly **wait**, but seriously who needs that ?)

## Future Roadmap

- [ ] *Finish the implementation of goproc*
- [ ] Add goproc support for windows (certainly by doing a wrapper around osproc)
- [ ] Add createGoPipe for windows
- [ ] Create more error handling in various libraries
- [ ] Adding more test cases
- [ ] Amelioration of efficiency of gonet
- [ ] Implement `GoChannel` a queue that can pass effienctly GC memory between coroutines and threads, without blocking the whole thread if waiting inside a coroutine. The thread queue has already been developped [here](https://github.com/Alogani/NimGo_multithreadingattempt/blob/main/src/nimgo/private/threadqueue.nim).


## Frequently asked questions


### Is it more efficient than async/await ?

No, the NimGo library is not more efficient than async/await. It is likely to be a bit slower and consume more memory than async/await. For most typical use cases, the performance difference will be negligible. However, for highly demanding scenarios like managing thousands of concurrent socket connections, you may notice a more significant impact.


### Why another async library, we already have std/asyncdispatch, chronos, etc ?

The NimGo library provides an alternative approach to handling asynchronous code compared to the existing options like std/asyncdispatch and chronos. The main difference is that classical async library "colors" (see that [article](https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/)) functions, meaning it modifies the function signature to include the asynchronous context.

This approach can offer some advantages, such as providing more control over the flow of data. However, it also comes with some drawbacks:
- Increased verbosity in the codebase
- Slower compilation speeds
- Potential "contamination" of the codebase, as the async library requires all related functions to be written using its asynchronous constructs.


### Is my code really async with NimGo ?

Yes, your code is indeed asynchronous when using NimGo, even if you don't explicitly see the asynchronous behavior. The asynchronicity is guaranteed by the type system, with types like GoFile and GoSocket abstractions that handle the underlying asynchronous operations.

Unlike some other approaches that rely on futures, NimGo uses the powerful concept of stackful coroutines. This means that any I/O call will automatically suspend the current function, allowing the runtime to execute other tasks, and then resume the function later when the I/O operation has completed.

You can control where the functions suspend and resume by using the goAsync and wait keywords provided by NimGo. This gives you a fine-grained control over the asynchronous flow of your code.


### Is NimGo multithreaded ?

No, NimGo's event loop can only run in a single thread. Any asynchronous tasks managed by NimGo cannot be shared between multiple threads.

However, it is possible to have multiple event loops, each running in their own separate thread. This allows you to parallelize asynchronous workloads across multiple threads. But you'll need to ensure strict separation between the event loops and their associated tasks to avoid any thread safety issues.


### Aren't there already existing approach, like CPS (Continuation passing style) ?

No, CPS (Continuation Passing Style) is not a specific I/O library, but rather a programming paradigm. It provides a way to structure code using continuations, which can enable concurrency through a technique called stackless coroutines.

Compared to the other async approach CPS with stackless coroutines offer some advantages:
- They can be more efficient in terms of memory usage and control flow.
- They provide fine-grained control over the data flow and execution.
- They may be better suited for certain use cases like compilers.
However, CPS and stackless coroutines also have some drawbacks:
- They are more complex and verbose to use compared to callback-based approaches.
- They can be less intuitive and harder to integrate with existing synchronous codebases.

It's important to note that the traditional async/await syntax in Nim is also a form of stackless coroutines, although implemented way differently. Instead NimGo choose to rely on stackful coroutines (also called green threads).

You can see https://github.com/nim-works/cps for more details. The developers of the [nimskull](https://github.com/nim-works/nimskull/pull/1249) compiler are planning to integrate a I/O library based on CPS. But for now, CPS remains a specialized programming paradigm, rather than a widely adopted I/O library.


## Example
You can find more example in [tests](https://github.com/Alogani/NimGo/tree/main/tests) folder or [benchmarks](https://github.com/Alogani/NimGo/tree/main/benchmarks) folder

```
import nimgo, nimgo/gofile


let MyFilePath = currentSourcePath()

## # Basic I/O
proc readAndPrint(file: GoFile) =
    # readAndPrint will be suspended until file.readLine return
    echo "MYLINE=", file.readLine()
    # file.readAll will be registered in dispatcher. readAndPrint can continue its execution
    var readTask: GoTask[string] = goAsync file.readAll()
    # we decide finally to get its data
    # readAndPrint will be suspended until readTask is finished
    echo "UNREADLENGTH=", (wait readTask).len()

block:
    var myFile = openGoFile(MyFilePath)
    withEventLoop():
        goAsync readAndPrint(myFile)
        echo "I'm not waiting for readAndPrint to finish !"
    echo "But `withEventLoop` ensures all registered tasks are executed"
    myFile.close()

## # Coroutines communication

## ## Returning a value:
block:
    proc getFirstLine(f: GoFile): string =
        f.readLine()
    var myFile = openGoFile(MyFilePath)
    echo "MYLINE=", wait goAsync getFirstLine(myFile)
    myFile.close()

## ## With closures:
proc main() =
    # Any GC value can be shared between coroutines
    var sharedData: string
    ## We have to use wait, otherwise sharedData will not be updated yet
    wait goAsync proc() =
        sharedData = "Inside the coroutine"
    echo sharedData
withEventLoop():
    main()


## # Unordered execution

proc printInDesorder(sleepTimeMs: int) =
    sleepAsync(sleepTimeMs)
    echo "> I woke up after ", sleepTimeMs, "ms"

withEventLoop():
    echo "Batch 1"
    goAsync printInDesorder(200)
    goAsync printInDesorder(100)
    goAsync printInDesorder(50)
# Or using waitAll
echo "Batch 2"
waitAll @[
    goAsync printInDesorder(110),
    goAsync printInDesorder(220),
    goAsync printInDesorder(60),
]

## Timeout

wait goAsync proc() =
    echo "Please input from stdin: "
    var data = goStdin.readChunk(timeoutMs = 500)
    if data.len() == 0:
        echo "> Too late"
    else:
        echo "> So fast, you have succesfully written: ", data

```
