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
- [ ] Adding more test cases
- [ ] Amelioration of efficiency of gonet
- [ ] Implement `GoChannel` a queue that can pass effienctly GC memory between coroutines and threads, without blocking the whole thread if waiting inside a coroutine. The thread queue has already been developped [here](https://github.com/Alogani/NimGo_multithreadingattempt/blob/main/src/nimgo/private/threadqueue.nim).


## Documentation

Full documentation can be browsered [here](https://htmlpreview.github.io/?https://github.com/Alogani/NimGo/blob/main/htmldocs/nimgo.html). The documentation is still under construction.

## Example
You can find more example in [tests](https://github.com/Alogani/NimGo/tree/main/tests) folder or [benchmarks](https://github.com/Alogani/NimGo/tree/main/benchmarks) folder

```nim
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
goAndWait proc() =
    echo "Please input from stdin: "
    var data = goStdin.readChunk(sleepTask(500))
    if data.len() == 0:
        echo "> Too late"
    else:
        echo "> So fast, you have succesfully written: ", data

```


## Frequently asked questions

### Can you give me a quicktour of the modules ?

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


### What do Araq thinks of it ?

"Looks nice and has good ideas. But what's the benefit of this over just using threads? Coorperative scheduling is bug-prone much like multi-threading is IMHO without its performance benefits." from [Araq, creator of Nim language and its main developper, 07/06/2024](https://forum.nim-lang.org/t/11720)


### What are coroutines? Can you explain the difference between stackful and stackless coroutines?

Coroutines are a way to have multiple tasks running within a single thread of execution. They allow you to pause a task, save its state, and then resume it later. NimGo use them internally and more precisely stackful coroutines.

**Stackful Coroutines:**
- These coroutines have their own call stack, which is managed by the coroutine library.
- When a stackful coroutine is paused, its entire call stack is saved, so it can resume exactly where it left off.
- This gives you more flexibility and control, but it also uses more memory and requires more work to manage the call stack.

**Stackless Coroutines:**
- These coroutines don't have their own call stack. Instead, they use the existing call stack of the underlying thread.
- When a stackless coroutine is paused, it simply yields control back to the calling code, without saving any call stack information.
- This is more lightweight and efficient, but it also means you have less control over the flow of execution, and you can't easily handle complex function calls or recursion.

In the case of NimGo, the library uses stackful coroutines, which provide more power and flexibility, but also require more careful management. The lower-level modules expose the details of the stackful coroutines, while the higher-level modules abstract away the complexity for most users.


### Is it more efficient than async/await ?

No, the NimGo library is not more efficient than async/await. It is likely to be a bit slower and consume more memory than async/await. For most typical use cases, the performance difference will be negligible. However, for highly demanding scenarios like managing thousands of concurrent socket connections, you may notice a more significant impact.


### Is it more efficient than Os threads ?

It depends on the task:
- For I/O-bound tasks, async/await-based concurrency (e.g., std/asyncdispatch or NimGo) are generally faster threads, as they can handle multiple I/O events concurrently without the overhead of managing multiple threads.
- For CPU-bound computation tasks, threads are generally faster than single-threaded async libraries, as they can leverage parallel execution across multiple CPU cores to speed up the code.

Additionally, threads have a higher context switch cost compared to Coroutines. Threads also require more careful handling of deadlocks, synchronization, and have constraints when moving memory around. Please note that their usage are not exclusive.


### How to use NimGo in a multithreaded environment ?

Using NimGo's coroutines in a multithreaded environment requires some additional setup and considerations:

1. Set a new dispatcher for each thread:
  - For each new thread, you need to create a new global dispatcher using `newDispatcher()` and set it as the current dispatcher with `setCurrentThreadDispatcher()`.
  - Alternatively, you can use the `insideNewEventLoop` template, which will set up a new dispatcher for the duration of the block.
  - You must not use the same dispatcher in multiple threads, as it is not thread-safe.

2. Don't shared async objects across threads:
- Do not use any async objects (like GoTasks[T] or GoFile) that were defined before setting the new thread's dispatcher.
- Coroutines and the Dispatcher itself are not safe to move between threads.

3. Register shared objects in each thread using its file descriptor
- If you want to use an object (like goStdin) that was defined in another thread, you must register it again in the current thread. Here is an example with `goStdin`: 
```nim
## Thread 1:
var fd = goStdin.getOsFileHandle()
var myChan.send(fd)
## Thread 2:
var fd = myChan.recv()
var goStdin2 = newGoFile(fd, fmRead)
```
- However this approach could lead to data races if locks are not used. The event dispatcher could think an I/O object is ready and perform a blocking I/O call, effectivly blocking the whole thread is data was stolen by another thread.

All the other rules concerning sharing safely data between threads applies (use channels !)

### NimGo's memory usage skyrocket?

NimGo coroutines use a lot of virtual memory, but not much actual physical memory (RAM).

Here's why:
- NimGo gives each coroutine a large amount of virtual memory, just in case they need it.
- But coroutines only use the physical memory they actually need.
- The operating system only allocates physical memory pages as the coroutines use them.
- So the high virtual memory usage doesn't mean high RAM usage. It's just a way to let the coroutines grow if they need to.

The virtual memory usage may look high, but the actual RAM usage is much lower. This design doesn't prevent other programs from running. You can see the real memory usage by NimGo by looking at RESIDENT (RES) memory in the top command.


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


### But I heard all files operations were synchronous ?

That's a common misconception. The operating system does consider regular file operations to be instantaneous, but that's not the case for all file-related tasks. Asynchronous I/O is generally not possible for regular files, which can impact the behavior of I/O libraries across programming languages (including std/asyncdispatch).

However, when there are potential sources of latency involved, such as reading from a remote server, the only solution is to use a separate thread. This allows the main application to continue running without being blocked by the file operation. There are plans to introduce a multi-threaded implementation of a channel in the future. This would allow the current coroutine to be blocked, without interrupting the entire event loop or dispatcher thread. This would simplify the handling of file operations with potential latency.


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

You can see https://github.com/nim-works/cps for more details. It also seems to exists an I/O library built on continuation [nim-sys](https://github.com/alaviss/nim-sys)


### When and how my function is executed ?

In NimGo, the behavior is different from the standard std/asyncdispatch library. When you use goAsync, your function is not executed immediately (but this behaviour could change in the future if it makes more sense). Instead, it is only executed when:

- You explicitly call wait on the specific task in your code.
- You call runEventLoop(), which is implicitly called when you use the withEventLoop template.

It is generally recommended to rely more on `withEventLoop()` or `runEventLoop()` rather than `wait`, to ensure that all coroutines created with goAsync are executed, even if you didn't explicitly wait for them.

Another key difference is that in NimGo, when your code is suspended, it doesn't pause the actual function itself. Instead, it can pause the entire code block executed with goAsync, allowing you to have an arbitrary depth of paused code (This recursion depth is limited by the implementation of the coroutines API in NimGo, which is typically between 1,000 and 5,000 levels, but could be lower if large stack variables like arrays are created inside a coroutine). You can think of goAsync as a checkpoint in your code, where the execution can be suspended and resumed later.


### Just Give Me the Coroutines, No Boilerplate

If you're not interested in all the boilerplate of I/O and event loops, and you just want to use coroutines directly with no additional overhead, you can do so by importing the nimgo/coroutines module.

By importing only nimgo/coroutines, you'll have access to the core coroutines API, which allows you to create, suspend, and resume coroutines. This gives you a lightweight way to work with coroutines without the additional complexity of the full NimGo framework.

However, it's important to note that by using only the coroutines API, you'll be limited in what you can do. The full power of NimGo comes from its integration with the event dispatcher/loop, which provide additional functionality for managing asynchronous tasks. If you want to leverage the dispatcher and event loop features, you can also import the nimgo/eventdispatcher module. This will give you access to the higher-level APIs for working with asynchronous code, while still allowing you to use the low-level coroutines primitives from the nimgo/coroutines module.


## Is it safe to use ? Stackful coroutines don't provide a high surface attack ?

The safety of using stackful coroutines, like those provided by NimGo, depends on how you write your code. The risk of a stack overflow attack is not inherently higher with coroutines than with other programming techniques.

NimGo employs various techniques to male stack overflow attacks more difficult.
- Heap-based stack allocation: NimGo allocates the coroutines' stacks using heap memory, rather than the process stack. This makes it harder for an attacker to inject code or modify other parts of the program's memory.
- Large default stack size: NimGo allocates a large chunk of (virtual) memory for each coroutine's stack by default. This reduces the likelihood of a stack overflow, even when using deep recursion or large stack variables.
- Stack page protection: NimGo marks the last page of each coroutine's stack as protected. This means the operating system will kill the program before a stack overflow can occur, preventing potential attacks.

## NimGo available flags

Here are what can be tweaked in NimGo (flags are case insensitive):

- `d:NimGoNoDebug` (already set on release mode): if this flags is set on:
  - a certain number of checks will be disabled inside NimGo, mainly to avoid nil deference
  - the creation stacktrace of Coroutines will not be recorded, so it will not be added to exceptions raised from inside a coroutine
  - no error message will be print in case of a stackoverflow within a Coroutine
- `-d:NimGoNoVMem` (only available on posix): If this flags is set, the Coroutines' stack won't be allocated using a virtual memory allocator but will use Nim's allocator (which use also generally virtual memory). The stack size of Coroutines won't be set by the internal value `VirtualStackSize`, but by the flag `PhysicalMemKib`
- `d:PhysicalMemKib:64` (only available on posix and when NimGoNoVMem flag is set. this is the default value): Allow to tweak the stack's size of each Coroutines. Lower value augments the risk of stackoverflow. Ideally, it would be a power of 2, but any value can be used. Please note that 4 Kib are always reserved to handle stackoverflow errors.

### Can I contribute

With pleasure :-)
