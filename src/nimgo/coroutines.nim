## Stackful asymmetric coroutines implementation, inspired freely from some language and relying on minicoro c library.
## Lighweight and efficient thanks to direct asm code and optional support for virtual memory.
## Push, pop and return value were not implemented, because type and GC safety cannot be guaranted, especially in multithreaded environment. Use Channels instead.

#[ ********* minicoroutines.h v0.2.0 wrapper ********* ]#
# Choice has been made to rely on minicoroutines for numerous reasons (efficient, single file, clear API, cross platform, virtual memory, etc.)
# Inspired freely from https://git.envs.net/iacore/minicoro-nim

when defined(release):
    const NimGoNoDebug = true
else:
    const NimGoNoDebug {.booldefine.} = false

const OnWindows = defined(windows) #-> to faciliate cross platform type debugging

when not defined(gcArc) and not defined(gcOrc):
    {.warning: "coroutines is not tested without --mm:orc or --mm:arc".}

import std/[bitops, oserrors, tables]
import ./private/[safecontainer, utils]
when OnWindows:
    import std/winlean
    {.warning: "Completly untested on windows. If I made a mistake the program will just early crash or won't compile".}
else:
    import std/posix

from std/os import parentDir, `/` 
const minicoroh = currentSourcePath().parentdir() / "private/minicoro.h"
{.compile: "./private/minicoro.c".}
when NimGoNoDebug:
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

{.push used.}
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
{.pop.}

proc checkMcoReturnCode(returnCode: McoReturnCode) =
    if returnCode != Success:
        raise newException(CoroutineError, $returnCode.prettyError())

#[ ********* Types ********* ]#

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
        when not NimGoNoDebug:
            creationStacktraceEntries: seq[StackTraceEntry]
    Coroutine* = ref CoroutineObj
        ## Basic coroutine object
        ## Thread safety: unstarted coroutine can be moved between threads
        ## Moving started coroutine, using resume/suspend are completely thread unsafe in ORC (and maybe ARC too)


#[ ********* Page size ********* ]#

when OnWindows:
    type
        SystemInfo {.importc: "_SYSTEM_INFO", header: "sysinfoapi.h".} = object 
            u1: uint32
            dwPageSize: uint32
            lpMinimumApplicationAddress: pointer
            lpMaximumApplicationAddress: pointer
            dwActiveProcessorMask: ptr uint32
            dwNumberOfProcessors*: uint32
            dwProcessorType: uint32
            dwAllocationGranularity*: uint32
            wProcessorLevel: uint16
            wProcessorRevision: uint16

    proc getSystemInfo(lpSystemInfo: ptr SystemInfo) {.stdcall,
                        importc: "GetSystemInfo", header: "sysinfoapi.h".}

    proc getSystemPageSize(): uint32 =
        var sysInfo: SystemInfo
        getSystemInfo(addr(sysInfo))
        return sysInfo.dwPageSize

    var PageSize = getSystemPageSize()
else:
    var PageSize = sysconf(SC_PAGESIZE)


#[ ********* Stack overflow handling ********* ]#

proc writeStackTraceEntries(entries: seq[StackTraceEntry]) =
    var entryStr: string
    for entry in entries:
        entryStr.add entry.filename
        entryStr.add "("
        entryStr.add $entry.line
        entryStr.add ") "
        entryStr.add entry.procname
        entryStr.add "\n"
        stderr.write(entryStr)
        stderr.flushFile()

when NimGoNoDebug:
    template recordProtectedPage*(coroPtr, protectedPage: pointer) = discard
    template unrecordProtectedPage*(coroPtr: pointer) = discard
else:
    var SegvWatcherMap: Table[ptr CoroutineObj, pointer]

    proc recordProtectedPage(coroPtr: ptr CoroutineObj, protectedPage: pointer) =
        SegvWatcherMap[coroPtr] = protectedPage

    proc unrecordProtectedPage(coroPtr: ptr CoroutineObj) =
        SegvWatcherMap.del(coroPtr)

    proc retrieveCoroutineAddr(segvAddress: pointer): pointer =
        ## Complexity O(n), but not important at this point
        ## Maybe unsafe, GC might be triggered between SIGSEGV and signal handler
        let segvAddrInt = cast[int](segvAddress)
        for (coroPtr, protectedPage) in pairs(SegvWatcherMap):
            let protectedPageInt = cast[int](protectedPage)
            if segvAddrInt >= protectedPageInt and segvAddrInt < protectedPageInt + int(PageSize):
                return coroPtr

when OnWindows and not NimGoNoDebug:
    type ExceptionRecord {.importc: "EXCEPTION_RECORD", header: "winnt.h".} = object 
        exceptionCode: int32
        exceptionFlags: int32
        exceptionRecord: ptr ExceptionRecord
        exceptionAddress: pointer
        numberOfParameters: int32
        exceptionInformation: pointer

    type ExceptionPointers {.importc: "_EXCEPTION_POINTERS", header: "winnt.h".} = object 
        exceptionRecord: ptr ExceptionRecord
        contextRecord: pointer
    
    const EXCEPTION_CONTINUE_SEARCH {.used.}: int64 = 0x0
    const EXCEPTION_EXECUTE_HANDLER: int64 = 0x1
    type UnhandledExceptionFilter = proc(exceptionInfo: ptr ExceptionPointers): int64 {.cdecl.}
    proc setUnhandledExceptionFilter(lpTopLevelExceptionFilter: UnhandledExceptionFilter): UnhandledExceptionFilter {.importc: "SetUnhandledExceptionFilter", header: "errhandlingapi.h".}

    proc segvHandler(exceptionInfo: ptr ExceptionPointers): int64 {.cdecl.} =
        let coroAddr = retrieveCoroutineAddr(exceptionInfo[].exceptionRecord[].exceptionAddress)
        if coroAddr != nil:
            stderr.write("Fatal error: Coroutine stackoverflow\n")
            stderr.write("Coroutine creation stacktrace:\n")
            writeStackTraceEntries(coroAddr[].creationStacktraceEntries)
            stderr.flushFile()
        return EXCEPTION_EXECUTE_HANDLER

    discard setUnhandledExceptionFilter(segvHandler)

when not(OnWindows or NimGoNoDebug):
    var SegvStackSize = MINSIGSTKSZ * 2
    
    # Having to redefine it, because amd64 SigAction on nim miss field `sa_sigaction`
    type Sigaction {.importc: "struct sigaction",
                    header: "<signal.h>", final, pure.} = object
            sa_handler*: proc (x: cint) {.noconv.}
            sa_mask*: Sigset
            sa_flags*: cint
            sa_sigaction*: proc (x: cint, y: ptr SigInfo, z: pointer) {.noconv.}
    proc sigaction(a1: cint, a2, a3: ptr Sigaction): cint {.importc, header: "<signal.h>".}
    proc sigaltstack(stackA, stackB: ptr Stack): cint {.importc, header: "<signal.h>".} # We redefine, because stackB can be nilable

    proc segvHandler(signum: cint, info: ptr SigInfo, data: pointer) {.noconv.} =
        ## Even if stacktrace or SegvWatcherMap were huge, they won't grow handler stack, so it should be safe
        ## Hopefully, the GC wasn't able to clean our unsafe memory
        let coroAddr = cast[ptr CoroutineObj](retrieveCoroutineAddr(info[].si_addr))
        if coroAddr != nil:
            stderr.write("Fatal error: Coroutine stackoverflow\n")
            stderr.write("Coroutine creation stacktrace:\n")
            writeStackTraceEntries(coroAddr[].creationStacktraceEntries)
            stderr.flushFile()
        exitnow(1)

    proc addSegvHandler() =
        var segvStack = Stack(
            ss_sp: alloc0(SegvStackSize),
            ss_size: SegvStackSize,
            ss_flags: 0,
        )
        discard sigaltstack(addr(segvStack), nil)
        var action = Sigaction(
            sa_flags: bitor(SA_SIGINFO, SA_ONSTACK),
            sa_sigaction: segvHandler,
        )
        discard sigaction(SIGSEGV, addr(action), nil)

    addSegvHandler()


#[ ********* Memory handling ********* ]#

const NimGoNoVMem* {.booldefine.} = false
const PhysicalMemKib {.intdefine.} = 64
const VirtualStackSize: uint = 4 * 1024 * 1024 # 4 MB should be more than enough and doesn't cost much more than 1 MB

var McoStackSize*: uint = (
    if NimGoNoVMem:
        PhysicalMemKib.uint * 1024'u
    else:
        VirtualStackSize
)

## Initial implementation of minicoro.h uses those functions to allocates the McoCoroutineStruct, its context and its stack alongside
## We ship our own modified version of minicoro.h where those functions only allocates the stack
proc mcoAllocator*(size: uint, allocatorData: ptr CoroutineObj): pointer {.cdecl.}
proc mcoDeallocator*(p: pointer, size: uint, allocatorData: ptr CoroutineObj) {.cdecl.}

when OnWindows:
    var MEM_COMMIT {.importc: "MEM_COMMIT", header: "<memoryapi.h>".}: cint
    var MEM_RESERVE {.importc: "MEM_RESERVE", header: "<memoryapi.h>".}: cint
    var MEM_RELEASE {.importc: "MEM_RESERVE", header: "<memoryapi.h>".}: cint

    proc VirtualAlloc(lpAddress: pointer, dwSize: uint, flAllocationType, flProtect: cint): pointer {.importc: "VirtualAlloc", header: "<memoryapi.h>".}
    proc VirtualFree(lpAdress: pointer, dwSize: uint, dwFreeType: cint): bool {.importc: "VirtualFree", header: "<memoryapi.h>".}
    proc VirtualProtect(lpAddress: pointer, dwSize: uint, flNewProtect: cint, lpflOldProect: var cint): bool {.importc: "VirtualProtect", header: "<memoryapi.h>".}

    proc mcoDeallocator*(p: pointer, size: uint, allocatorData: ptr CoroutineObj) {.cdecl.} =
        if not VirtualFree(p, 0, MEM_RELEASE):
            raiseOSError(osLastError())
        when not NimGoNoDebug:
            unrecordProtectedPage(allocatorData)

    proc mcoAllocator*(size: uint, allocatorData: ptr CoroutineObj): pointer {.cdecl.} =
        ## On windows, we will always use virtual memory
        result = VirtualAlloc(nil, size, bitor(MEM_COMMIT, MEM_RESERVE), PAGE_READWRITE)
        if result == nil:
            raiseOSError(osLastError())
        var oldProtect: cint
        if not VirtualProtect(result, 0x1000, PAGE_NOACCESS, oldProtect):
            ## Stack begins at its bottom
            mcoDeallocator(result, size, nil)
            raiseOSError(osLastError())
        when not NimGoNoDebug:
            recordProtectedPage(allocatorData, result)

else:
    var SC_PHYS_PAGES {.importc: "_SC_PHYS_PAGES", header: "<unistd.h>".}: cint

    var AvailableMemory = PageSize * sysconf(SC_PHYS_PAGES)

    if AvailableMemory > 0:
        McoStackSize = min(McoStackSize, (
            var res: uint
            setBit(res, fastlog2(AvailableMemory - 1))
            res
        )) ## For low memory systems
    if PageSize <= 0:
        raise newException(OSError, "Couldn't find the page size of a memory block")

    proc mcoDeallocator*(p: pointer, size: uint, allocatorData: ptr CoroutineObj) {.cdecl.} =
        when NimGoNoVMem:
            dealloc(p)
        else:
            if munmap(p, size.int) != 0:
                raiseOSError(osLastError())
        when not NimGoNoDebug:
            unrecordProtectedPage(allocatorData)

    proc mcoAllocator*(size: uint, allocatorData: ptr CoroutineObj): pointer {.cdecl.} =
        when NimGoNoVMem:
            result = alloc0(size)
        else:
            result = mmap(nil, size.int,
                bitor(PROT_READ, PROT_WRITE),
                bitor(MAP_PRIVATE, MAP_ANONYMOUS),
                -1, 0
            )
            if result == MAP_FAILED:
                raiseOSError(osLastError())
        if mprotect(result, PageSize, PROT_NONE) != 0:
            ## Stack begins at its bottom
            mcoDeallocator(result, size, nil)
            raiseOSError(osLastError())
        when not NimGoNoDebug:
            recordProtectedPage(allocatorData, result)


#[ ********* API ********* ]#

{.push stackTrace:off.}
# We disable stacktrace because moving around coroutines before resuming/suspending can mess it up

template enhanceExceptions(coroPtr: ptr CoroutineObj, body: untyped) =
    when NimGoNoDebug:
        `body`
    else:
        try:
            `body`
        except:
            var err = getCurrentException()
            # We will do dirty things. Not efficient, but at least very explicit
            {.warning[InheritFromException]:off.}
            type ChildException = ref object of Exception 
                gcmemory: seq[string]
            var newErr = cast[ChildException](err)
            for entry in mitems(newErr.trace):
                var newFilename = ">" & $entry.filename
                newErr.gcmemory.add newFilename
                entry.filename = cstring(newErr.gcmemory[^1])
            for entry in mitems(coroPtr[].creationStacktraceEntries):
                var newFilename = ">" & $entry.filename
                newErr.gcmemory.add newFilename
                entry.filename = cstring(newErr.gcmemory[^1])
            newErr.trace = (
                @[StackTraceEntry(filename: cstring"Coroutine creation:")] &
                coroPtr[].creationStacktraceEntries &
                @[StackTraceEntry(filename: cstring"Coroutine execution:")] &
                err.trace)
            setCurrentException(newErr)
            raise

proc coroutineMain[T](mcoCoroutine: ptr McoCoroutine) {.cdecl.} =
    ## Start point of the coroutine.
    let coroPtr = cast[ptr CoroutineObj](mcoCoroutine.getUserData())
    let entryFn = cast[SafeContainer[EntryFn[T]]](coroPtr[].entryFn).popFromContainer()
    enhanceExceptions(coroPtr):
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
## Useful to use with a coroutine pool. However, will certainly not play nicely with virtual memory.
## Furthermore, this code is now outdated
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
    when not NimGoNoDebug:
        result.creationStacktraceEntries = getStackTraceEntries()
        mcoCoroDescriptor.allocator_data = mcoCoroDescriptor.user_data
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
{.pop.}

proc getCurrentCoroutine*(): Coroutine =
    ## Get the actual running coroutine
    ## If we are not inside a coroutine, nil is retuned
    return cast[Coroutine](getRunningMco().getUserData())

proc getCurrentCoroutineSafe*(): Coroutine =
    ## Additional check on debug to verify we are inside a coroutine
    when NimGoNoDebug:
        getCurrentCoroutine()
    else:
        result = getCurrentCoroutine()
        if result == nil:
            raise newException(ValueError, "We are not inside a coroutine")

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
