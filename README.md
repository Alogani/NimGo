# NimGo

_NimGo: Asynchronous Library Inspired by Go's Asyncio. Or for Purists: Stackful Coroutines library associated with an I/O Event Loop and Dispatcher_

This repository is currently an alpha release. Breaking change and API redesign won't be avoided.


## Goal
Provide a simple, concise and efficient library for I/O.

No async/await, no pragma, no Future[T] everywhere !

Only one word to remember : **goAsync** (and optionaly **wait**, but seriously who needs that ?)

## Current state

All working features can be found [here](https://github.com/Alogani/NimGo/discussions/26).

For now, NimGo is a single-threaded library. On Araq's advice (and maybe it's help), NimGo will be transformed towards a multi-threaded library (like Golang). This specific transformation has its own roadmap that can be found [here](https://github.com/Alogani/NimGo/discussions/17).

## Documentation

Full documentation can be browsered [here](https://htmlpreview.github.io/?https://github.com/Alogani/NimGo/blob/main/htmldocs/nimgo.html). The documentation is still under construction.

## Contributions

They are welcomed and any help is valuable. A code of contribution can be found [here](https://github.com/Alogani/NimGo/blob/main/CONTRIBUTING.md).

## Example

The following working example will give you an idea of how NimGo works and how to use it.

```nim
# Depending on your OS, the following example might not yet work

import nimgo, nimgo/gofile


let MyFilePath = currentSourcePath()

## # Basic I/O
proc readAndPrint(file: GoFile) =
# readAndPrint will be suspended until file.readLine return
echo "MYLINE=", file.readLine()
# file.readAll will be registered in dispatcher. readAndPrint can continue its execution
var readTask: GoTask[string] = go file.readAll()
# we decide finally to get its data
# readAndPrint will be suspended until readTask is finished
echo "UNREADLENGTH=", (wait readTask).len()

withEventLoop():
var myFile = openGoFile(MyFilePath)
goAndWait readAndPrint(myFile)
echo "I'm not waiting for readAndPrint to finish !"
echo "But `withEventLoop` ensures all registered tasks are executed"
myFile.close()

## # Coroutines communication

## ## Returning a value:
block:
proc getFirstLine(f: GoFile): string =
    f.readLine()
var myFile = openGoFile(MyFilePath)
echo "MYLINE=", goAndWait getFirstLine(myFile)
myFile.close()

## ## With closures:
proc main() =
# Any GC value can be shared between coroutines
var sharedData: string
## We have to use wait, otherwise sharedData will not be updated yet
goAndWait proc() =
    sharedData = "Inside the coroutine"
echo sharedData
main()


## # Unordered execution

proc printInDesorder(sleepTimeMs: int) =
sleepAsync(sleepTimeMs)
echo "> I woke up after ", sleepTimeMs, "ms"

withEventLoop():
echo "Batch 1"
go printInDesorder(200)
go printInDesorder(100)
go printInDesorder(50)
# Or using waitAll
echo "Batch 2"
waitAll @[
go printInDesorder(110),
go printInDesorder(220),
go printInDesorder(60),
]

## Timeout
goAndWait proc() =
echo "Please input from stdin: "
var data = goStdin.readChunk(timeoutMs = 500)
if data.len() == 0:
    echo "> Too late"
else:
    echo "> So fast, you have succesfully written: ", data

```

Here are the place wher eyou can find more examples:
- [tests](https://github.com/Alogani/NimGo/tree/main/tests) folder
- [benchmarks](https://github.com/Alogani/NimGo/tree/main/benchmarks) folder


## Quicktour of the modules

Certainly! The NimGo library consists of the following key modules:

- nimgo: This module provides the necessary tools to create and manage the flow of execution.
- nimgo/gofile: This module offers all the asynchronous I/O operations for files and pipes.
- nimgo/gostreams: This module provides an internal channel called GoBufferStream, as well as a common API for working with this channel and files.
- nimgo/gonet: This module handles all the operations for working with sockets asynchronously.
- nimgo/goproc: This module exposes an API for creating child processes, executing commands, and interacting with them asynchronously.
- nimgo/coroutines: This module provides the low-level API for the stackful coroutines, which is abstracted away for most users.
- nimgo/eventdispatcher: This module exposes the low-level API for using the event loop and dispatcher.
- nimgo/public/gotasks: This module is already imported with the nimgo package and provides the `GoTask` abstraction for manipulating the flow of execution and return values.

Most users will primarily interact with the higher-level modules like nimgo, nimgo/gofile, nimgo/gonet, and nimgo/public/gotasks, while the lower-level modules (nimgo/coroutines and nimgo/eventdispatcher) are intended for more advanced use cases.

## Miscelleanous


### What do Araq thinks of it ?

"Looks nice and has good ideas. But what's the benefit of this over just using threads? Coorperative scheduling is bug-prone much like multi-threading is IMHO without its performance benefits." from [Araq, creator of Nim language and its main developper, 07/06/2024](https://forum.nim-lang.org/t/11720)

### How does it work ?

If you are interested to know more about NimGo and Coroutines, you can check the wiki !

### NimGo seems to have a high memory usage ?

NimGo coroutines use a lot of virtual memory, but not much actual physical memory (RAM).

Here's why:
- NimGo gives each coroutine a large amount of virtual memory, just in case they need it.
- But coroutines only use the physical memory they actually need.
- The operating system only allocates physical memory pages as the coroutines use them.
- So the high virtual memory usage doesn't mean high RAM usage. It's just a way to let the coroutines grow if they need to.

The virtual memory usage may look high, but the actual RAM usage is much lower. This design doesn't prevent other programs from running. You can see the real memory usage by NimGo by looking at RESIDENT (RES) memory in the top command.


