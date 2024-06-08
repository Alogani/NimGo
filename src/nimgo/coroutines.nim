## Stackful asymmetric coroutines implementation, inspired freely from some language and relying on minicoro c library.
## Lighweight and efficient thanks to direct asm code and optional support for virtual memory.
## Push, pop and return value were not implemented, because type and GC safety cannot be guaranted, especially in multithreaded environment. Use Channels instead.

#[ ********* minicoroutines.h v0.2.0 wrapper ********* ]#
# Choice has been made to rely on minicoroutines for numerous reasons (efficient, single file, clear API, cross platform, virtual memory, etc.)
# Inspired freely from https://git.envs.net/iacore/minicoro-nim


{.push stackTrace:off.}
#[
    We disable stacktrace for this file because moving around coroutines before resuming/suspending can mess it up
]#

import ./private/coroutinememory

when not defined(gcArc) and not defined(gcOrc):
    {.warning: "coroutines is not tested without --mm:orc or --mm:arc".}

from std/os import parentDir, `/` 
const minicoroh = currentSourcePath().parentdir() / "private/minicoro.h"
    
{.compile: "./private/minicoro.c".}
when not defined(debug):
    {.passC: "-DMCO_NO_DEBUG".}


type
    McoCoroDescriptor {.importc: "mco_desc", header: minicoroh.} = object
        ## Contains various propery used to init a coroutine
        entryFn: pointer
        user_data*: pointer ## Only this one is useful to us
        alloc_cb: pointer
        dealloc_cb: pointer
        allocator_data: pointer
        storage_size: uint
        coro_size: uint
        stack_size: uint

    McoReturnCode {.pure, importc: "mco_result", header: minicoroh.} = enum
        Success = 0,
        GenericError,
        InvalidPointer,
        InvalidCoroutine,
        NotSuspended,
        NotRunning,
        Makecontext_Error,
        Switchcontext_Error,
        NotEnoughSpace,
        OutOfMemory,
        InvalidArguments,
        InvalidOperation,
        StackOverflow,

    CoroutineError* = object of OSError

    McoCoroState {.importc: "mco_state", header: minicoroh.} = enum
        # The original name were renamed for clarity
        McoCsFinished = 0, ## /* The coroutine has finished normally or was uninitialized before finishing. */
        McoCsParenting, ## /* The coroutine is active but not running (that is, it has resumed another coroutine). */
        McoCsRunning, ## /* The coroutine is active and running. */
        McoCsSuspended ## /* The coroutine is suspended (in a call to yield, or it has not started running yet). */

    McoCoroutine {.importc: "mco_coro", header: minicoroh.} = object
        ## Internals we don't touch
        context: pointer
        mco_state: McoCoroState
        prev_co: pointer
        user_data: pointer
        coro_size: uint
        allocator_data: pointer
        alloc_cb: pointer
        dealloc_cb: pointer
        stack_base: pointer
        stack_size: uint
        storage: pointer
        bytes_stored: uint
        storage_size: uint
        asan_prev_stack: pointer
        tsan_prev_fiber: pointer
        tsan_fiber: pointer
        magic_number: uint

    cstring_const {.importc:"const char*", header: minicoroh.} = cstring

proc initMcoDescriptor(entryFn: proc (coro: ptr McoCoroutine) {.cdecl.}, stackSize: uint): McoCoroDescriptor {.importc: "mco_desc_init", header: minicoroh.}
proc initMcoCoroutine(coro: ptr McoCoroutine, descriptor: ptr McoCoroDescriptor): McoReturnCode {.importc: "mco_init", header: minicoroh.}
proc uninitMcoCoroutine(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_uninit", header: minicoroh.}
proc createMcoCoroutine(outCoro: ptr ptr McoCoroutine, descriptor: ptr McoCoroDescriptor): McoReturnCode {.importc: "mco_create", header: minicoroh.}
proc destroyMco(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_destroy", header: minicoroh.}
proc resume(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_resume", header: minicoroh.}
proc suspend(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_yield", header: minicoroh.}
proc getState(coro: ptr McoCoroutine): McoCoroState {.importc: "mco_status", header: minicoroh.}
proc getUserData(coro: ptr McoCoroutine): pointer {.importc: "mco_get_user_data", header: minicoroh.}
proc getRunningMco(): ptr McoCoroutine {.importc: "mco_running", header: minicoroh.}
proc prettyError(returnCode: McoReturnCode): cstring_const {.importc: "mco_result_description", header: minicoroh.}

proc checkMcoReturnCode(returnCode: McoReturnCode) =
    if returnCode != Success:
        raise newException(CoroutineError, $returnCode.prettyError())


#[ ********* API ********* ]#

import ./private/[safecontainer, utils]

type
    CoroState* = enum
        CsRunning
        CsParenting ## The coroutine is active but not running (that is, it has resumed another coroutine).
        CsSuspended
        CsFinished
    
    EntryFn*[T] = proc(): T
        ## Supports at least closure and nimcall calling convention
    
    CoroutineObj = object
        entryFn: SafeContainer[void]
        returnedVal: pointer
        mcoCoroutine: ptr McoCoroutine
    Coroutine* = ref CoroutineObj
        ## Basic coroutine object
        ## Thread safety: unstarted coroutine can be moved between threads
        ## Moving started coroutine, using resume/suspend are completely thread unsafe in ORC (and maybe ARC too)

proc coroutineMain[T](mcoCoroutine: ptr McoCoroutine) {.cdecl.} =
    ## Start point of the coroutine.
    let coroPtr = cast[ptr CoroutineObj](mcoCoroutine.getUserData())
    let entryFn = cast[SafeContainer[EntryFn[T]]](coroPtr[].entryFn).popFromContainer()
    when T isnot void:
        let res = entryFn()
        coroPtr[].returnedVal = allocAndSet(res.pushIntoContainer())
    else:
        entryFn()

proc destroyMcoCoroutine(coroObj: CoroutineObj) =
    checkMcoReturnCode destroyMco(coroObj.mcoCoroutine)


when defined(nimAllowNonVarDestructor):
    proc `=destroy`*(coroObj: CoroutineObj) =
        ## Unfinished coroutines clean themselves. However, it is not sure its heap memory will be cleaned up, resulting in a leakage
        ## It is always better to resume a coroutine until its end
        if coroObj.mcoCoroutine != nil:
            try:
                destroyMcoCoroutine(coroObj)
            except:
                discard
        if coroObj.returnedVal != nil:
            deallocShared(coroObj.returnedVal)
        coroObj.entryFn.destroy()
else:
    proc `=destroy`*(coroObj: var CoroutineObj) =
        ## Unfinished coroutines clean themselves. However, it is not sure its heap memory will be cleaned up, resulting in a leakage
        ## It is always better to resume a coroutine until its end
        if coroObj.mcoCoroutine != nil:
            try:
                destroyMcoCoroutine(coroObj)
            except:
                discard
        if coroObj.returnedVal != nil:
            deallocShared(coroObj.returnedVal)
        coroObj.entryFn.destroy()

#[
proc reinitImpl[T](coro: Coroutine, entryFn: EntryFn[T]) =
    checkMcoReturnCode uninitMcoCoroutine(coro.mcoCoroutine)
    coro.entryFn = cast[SafeContainer[void]](entryFn.pushIntoContainer())
    var mcoCoroDescriptor = initMcoDescriptor(coroutineMain[T], coro.mcoCoroutine[].stack_size)
    mcoCoroDescriptor.user_data = cast[ptr CoroutineObj](coro)
    checkMcoReturnCode initMcoCoroutine(coro.mcoCoroutine, addr mcoCoroDescriptor)

proc reinit*[T](coro: Coroutine, entryFn: EntryFn[T]) =
    reinitImpl[T](coro, entryFn)

proc reinit*(coro: Coroutine, entryFn: EntryFn[void]) =
    ## Allow to reuse an existing coroutine without reallocating it
    ## However, please ensure it has correctly finished
    reinitImpl[void](coro, entryFn)
]#

proc newCoroutineImpl[T](entryFn: EntryFn[T]): Coroutine =
    result = Coroutine(
        entryFn: cast[SafeContainer[void]](entryFn.pushIntoContainer()),
    )
    var mcoCoroDescriptor = initMcoDescriptor(coroutineMain[T], McoStackSize)
    mcoCoroDescriptor.alloc_cb = mcoAllocator
    mcoCoroDescriptor.dealloc_cb = mcoDeallocator
    mcoCoroDescriptor.user_data = cast[ptr CoroutineObj](result)
    checkMcoReturnCode createMcoCoroutine(addr(result.mcoCoroutine), addr mcoCoroDescriptor)


proc newCoroutine*[T](entryFn: EntryFn[T]): Coroutine =
    newCoroutineImpl[T](entryFn)

proc newCoroutine*(entryFn: EntryFn[void]): Coroutine =
    newCoroutineImpl[void](entryFn)

proc resume*(coro: Coroutine) =
    ## Will resume the coroutine where it stopped (or start it)
    let frame = getFrameState()
    checkMcoReturnCode resume(coro.mcoCoroutine)
    setFrameState(frame)

proc suspend*() =
    ## Suspend the actual running coroutine
    let frame = getFrameState()
    checkMcoReturnCode suspend(getRunningMco())
    setFrameState(frame)

proc suspend*(coro: Coroutine) =
    ## Optimization to avoid calling getRunningMco() twice which has some overhead
    ## Never use if coro is different than current coroutine
    let frame = getFrameState()
    checkMcoReturnCode suspend(coro.mcoCoroutine)
    setFrameState(frame)

proc getCurrentCoroutine*(): Coroutine =
    ## Get the actual running coroutine
    ## If we are not inside a coroutine, nil is retuned
    return cast[Coroutine](getRunningMco().getUserData())

proc getCurrentCoroutineSafe*(): Coroutine =
    ## Additional check on debug to verify we are inside a coroutine
    when defined(debug):
        result = getCurrentCoroutine()
        if result == nil:
            raise newException(ValueError, "We are not inside a coroutine")
    else:
        getCurrentCoroutine()

proc getReturnVal*[T](coro: Coroutine): T =
    if coro.returnedVal == nil:
        raise newException(ValueError, "Coroutine don't have a return value or is not finished")
    result = cast[ptr SafeContainer[T]](coro.returnedVal)[].popFromContainer()
    deallocShared(coro.returnedVal)
    coro.returnedVal = nil

proc finished*(coro: Coroutine): bool =
    ## Finished either with error or success
    coro.mcoCoroutine.getState() == McoCsFinished

proc getState*(coro: Coroutine): CoroState =
    case coro.mcoCoroutine.getState():
    of McoCsFinished:
        CsFinished
    of McoCsParenting:
        CsParenting
    of McoCsRunning:
        CsRunning
    of McoCsSuspended:
        CsSuspended
