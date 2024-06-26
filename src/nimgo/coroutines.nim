## Stackful asymmetric coroutines implementation, inspired freely from some language and relying on minicoro c library.
## Lighweight and efficient thanks to direct asm code and optional support for virtual memory.
## Push, pop and return value were not implemented, because type and GC safety cannot be guaranted, especially in multithreaded environment. Use Channels instead.

#[ ********* minicoroutines.h v0.2.0 wrapper ********* ]#
# Choice has been made to rely on minicoroutines for numerous reasons (efficient, single file, clear API, cross platform, virtual memory, etc.)
# Inspired freely from https://git.envs.net/iacore/minicoro-nim


import ./private/[compiletimeflags, memallocs, utils]
import std/isolation

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


proc initMcoDescriptor(entryFn: proc (coro: ptr McoCoroutine) {.cdecl.}, stackSize: uint): McoCoroDescriptor {.importc: "mco_desc_init", header: minicoroh.}
proc initMcoCoroutine(coro: ptr McoCoroutine, descriptor: ptr McoCoroDescriptor): McoReturnCode {.importc: "mco_init", header: minicoroh.}
proc uninitMcoCoroutine(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_uninit", header: minicoroh.}
proc resume(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_resume", header: minicoroh.}
proc suspend(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_yield", header: minicoroh.}
proc getState(coro: ptr McoCoroutine): McoCoroState {.importc: "mco_status", header: minicoroh.}
proc getUserData(coro: ptr McoCoroutine): pointer {.importc: "mco_get_user_data", header: minicoroh.}
proc getRunningMco(): ptr McoCoroutine {.importc: "mco_running", header: minicoroh.}
proc prettyError(returnCode: McoReturnCode): cstring_const {.importc: "mco_result_description", header: minicoroh.}


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
  
  EntryFnContainer[T] = object
    entryFn: EntryFn[T]

  CoroutineObj = object
    entryFnContainer: EntryFnContainer[void]
    callBackEnv: ForeignCell
    returnedVal: ptr Isolated[void]
    mcoCoroutine: ptr McoCoroutine
    exception: ref Exception
    when not NimGoNoDebug:
      parent: ptr CoroutineObj
      creationStacktraceEntries: seq[StackTraceEntry]
  Coroutine* = ref CoroutineObj
    ## Basic coroutine object
    ## Thread safety: unstarted coroutine can be moved between threads
    ## Moving started coroutine, using resume/suspend are completely thread unsafe in ORC (and maybe ARC too)

const StackTraceHeaderCreation = cstring"> Coroutine creation stacktrace"
const StackTraceHeaderExecution = cstring"> Coroutine execution stacktrace"


#[ ********* Stack overflow / Stacktrace handling ********* ]#

when not NimGoNoDebug:
  proc mergeStackTraceEntries(coroPtr: ptr CoroutineObj): seq[StackTraceEntry] =
    var stack: seq[ptr CoroutineObj]
    var actualCoro = coroPtr
    var entries: seq[StackTraceEntry]
    while actualCoro != nil:
      stack.add actualCoro
      actualCoro = actualCoro.parent
    var z = stack.len()
    for i in countdown(z - 1, 0):
      entries.add StackTraceEntry(filename: StackTraceHeaderCreation, line: z - i)
      entries.add stack[i][].creationStacktraceEntries
    entries

proc writeStackTraceEntries(entries: seq[StackTraceEntry]) =
  for entry in entries:
    var entryStr: string
    entryStr.add entry.filename
    entryStr.add "("
    entryStr.add $entry.line
    entryStr.add ") "
    entryStr.add entry.procname
    entryStr.add "\n"
    stderr.write(entryStr)
    stderr.flushFile()

when not NimGoNoDebug:
  addSegvHandler(segvAddr):
    # Hopefully, the GC wasn't able to clean our unsafe memory
    let coroAddr = cast[ptr CoroutineObj](
      retrieveAllocatorDataFromSigsegv(segvAddr))
    if coroAddr != nil:
      stderr.write("Fatal error: Coroutine stackoverflow\n")
      stderr.flushFile()
      writeStackTraceEntries(mergeStackTraceEntries(coroAddr))


#[ ********* API ********* ]#

{.push stackTrace:off.}
# We disable stacktrace because moving around coroutines before resuming/suspending can mess it up

template enhanceExceptions(coroPtr: ptr CoroutineObj, body: untyped) =
  when NimGoNoDebug:
    `body`
  else:
    try:
      `body`
    except CatchableError:
      var err = getCurrentException()
      if err.trace[0].filename != StackTraceHeaderCreation:
        err.trace = (mergeStackTraceEntries(coroPtr) &
          @[StackTraceEntry(filename: StackTraceHeaderExecution)] &
          err.trace)
      Gc_ref(err)
      coroPtr.exception = err

proc coroutineMain[T](mcoCoroutine: ptr McoCoroutine) {.cdecl.} =
  ## Start point of the coroutine.
  let coroPtr = cast[ptr CoroutineObj](mcoCoroutine.getUserData())
  let entryFn = cast[EntryFnContainer[T]](coroPtr[].entryFnContainer).entryFn
  enhanceExceptions(coroPtr):
    when T isnot void:
      let res = entryFn()
      coroPtr[].returnedVal = cast[ptr Isolated[void]](allocAndSet(isolate(res)))
    else:
      entryFn()

proc destroyMcoCoroutine(coroObj: CoroutineObj) =
  checkMcoReturnCode uninitMcoCoroutine(coroObj.mcoCoroutine)
  deallocShared(coroObj.mcoCoroutine)


when defined(nimAllowNonVarDestructor):
  proc `=destroy`*(coroObj: CoroutineObj) =
    ## Unfinished coroutines clean themselves. However, it is not sure its heap memory will be cleaned up, resulting in a leakage
    ## It is always better to resume a coroutine until its end
    if coroObj.mcoCoroutine != nil:
      try:
        destroyMcoCoroutine(coroObj)
      except:
        discard
    dispose(coroObj.callBackEnv)
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
    dispose(coroObj.callBackEnv)


proc getCurrentCoroutine*(): Coroutine


proc newCoroutineImpl[T](entryFn: EntryFn[T]): Coroutine =
  result = Coroutine(
    entryFnContainer: cast[EntryFnContainer[void]](EntryFnContainer[T](entryFn: entryFn)),
    callBackEnv: protect(rawEnv(entryFn))
  )
  var mcoCoroDescriptor = initMcoDescriptor(coroutineMain[T], StackSize.uint)
  mcoCoroDescriptor.alloc_cb = mcoStackAllocator
  mcoCoroDescriptor.dealloc_cb = mcoStackDeallocator
  mcoCoroDescriptor.user_data = cast[ptr CoroutineObj](result)
  when not NimGoNoDebug:
    let coro = getCurrentCoroutine()
    if coro != nil:
      result.parent = cast[ptr CoroutineObj](coro)
    result.creationStacktraceEntries = getStackTraceEntries()
    mcoCoroDescriptor.allocator_data = mcoCoroDescriptor.user_data
  result.mcoCoroutine = cast[ptr McoCoroutine](allocShared0(mcoCoroDescriptor.coro_size))
  checkMcoReturnCode initMcoCoroutine(result.mcoCoroutine, addr mcoCoroDescriptor)


proc newCoroutine*[T](entryFn: EntryFn[T]): Coroutine =
  newCoroutineImpl[T](entryFn)

proc newCoroutine*(entryFn: EntryFn[void]): Coroutine =
  newCoroutineImpl[void](entryFn)

proc resume*(coro: Coroutine) =
  ## Will resume the coroutine where it stopped (or start it)
  let frame = getFrameState()
  checkMcoReturnCode resume(coro.mcoCoroutine)
  setFrameState(frame)
  if coro.exception != nil:
    GC_unref(coro.exception)
    setCurrentException(coro.exception)
    raise

proc suspend*() =
  ## Suspend the actual running coroutine
  let frame = getFrameState()
  let currentMco = getRunningMco()
  checkMcoReturnCode suspend(currentMco)
  setFrameState(frame)
  let coroPtr = cast[ptr CoroutineObj](currentMco.getUserData())
  if coroPtr[].exception != nil:
    GC_unref(coroPtr[].exception)
    setCurrentException(coroPtr[].exception)
    raise

proc suspend*(coro: Coroutine) =
  ## Optimization to avoid calling getRunningMco() twice which has some overhead
  ## Never use if coro is different than current coroutine
  let frame = getFrameState()
  checkMcoReturnCode suspend(coro.mcoCoroutine)
  setFrameState(frame)
  if coro.exception != nil:
    GC_unref(coro.exception)
    setCurrentException(coro.exception)
    raise
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
  result = cast[ptr Isolated[T]](coro.returnedVal)[].extract()
  dealloc(coro.returnedVal)
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
