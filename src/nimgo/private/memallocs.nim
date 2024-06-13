#[
  It has been choosed to rely on Nim's allocator system. Which presents advantages and drawbaks.
  https://github.com/Alogani/NimGo/issues/16#issuecomment-2163246129
]#
when not defined(gcArc) and not defined(gcOrc):
  {.warning: "Coroutines only works with --mm:orc or --mm:arc".}

import ./compiletimeflags
import std/[bitops, tables, exitprocs, macros]

#[ ********* Protection policy ********* ]#

# lib/system/bitmasks
const
  PageShift = when defined(nimPage256) or defined(cpu16): 3
    elif defined(nimPage512): 9
    elif defined(nimPage1k): 10
    else: 12 # \ # my tests showed no improvements for using larger page sizes.

  PageSize = 1 shl PageShift
  PageMask = PageSize-1


proc getFirstAlignedAddr(p: pointer): pointer =
  ## Necessary for page protection
  ## Not much costly to compute it each time instead of using a special object
  var pMath = cast[int](p)
  return cast[pointer](pMath + PageSize - (pMath and PageMask))

# lib/system/osalloc
when defined(windows):
  import std/winlean
  const
    MEM_RESERVE = 0x2000
    MEM_COMMIT = 0x1000
    MEM_TOP_DOWN = 0x100000
    PAGE_READWRITE = 0x04

    MEM_DECOMMIT = 0x4000
    MEM_RELEASE = 0x8000

  proc VirtualProtect(lpAddress: pointer, dwSize: int,
          flNewProtect: cint, lpflOldProect: var cint): bool {.header: "<windows.h>",
          importc: "VirtualProtect".} # header: "<memoryapi.h>" ?

  proc protectPointerBegin(p: pointer): bool =
    var oldProtect: cint
    return VirtualProtect(getFirstAlignedAddr(p), 0x1000, PAGE_NOACCESS, oldProtect)

  proc unProtectPointerBegin(p: pointer): bool =
    var oldProtect: cint
    return VirtualProtect(getFirstAlignedAddr(p), 0x1000, PAGE_READWRITE, oldProtect)
else:
  import std/posix

  proc protectPointerBegin(p: pointer): bool =
    return mprotect(getFirstAlignedAddr(p), PageSize, PROT_NONE) == 0

  proc unProtectPointerBegin(p: pointer): bool =
    return mprotect(getFirstAlignedAddr(p), PageSize, bitor(PROT_READ, PROT_WRITE)) == 0


#[ ********* Stackoverflow catcher ********* ]#

when defined(windows) and not NimGoNoDebug:
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

  macro addSegvHandler*(segvAddr, body: untyped): untyped =
    ## To use at top level
    let segvHandler = genSym(nskProc)
    return quote do:
      proc `segvHandler`(exceptionInfo: ptr ExceptionPointers): int64 {.noconv.} =
        let `segvAddr` = exceptionInfo[].exceptionRecord[].exceptionAddress
        `body`
        return EXCEPTION_EXECUTE_HANDLER

      if not setUnhandledExceptionFilter(`segvHandler`):
        stderr.write("Warning: couldn't set SigSegv handler")
        stderr.flushFile()

when not(defined(windows) or NimGoNoDebug):
  # We redefine, because stackB can be nilable
  proc sigaltstack(stackA, stackB: ptr Stack): cint {.importc, header: "<signal.h>".}

  var SegvStackSize = MINSIGSTKSZ * 2

  proc addSegvHandlerHelper(handler: proc(signum: cint, info: ptr SigInfo, data: pointer) {.cdecl.}) =
    ## Even if stacktrace or SegvWatcherMap were huge, they won't grow handler stack, so it should be safe
    var segvStackPtr = alloc0(SegvStackSize)
    var segvStack = Stack(
      ss_sp: segvStackPtr,
      ss_size: SegvStackSize,
      ss_flags: 0,
    )
    addExitProc(proc() = dealloc(segvStackPtr))
    if sigaltstack(addr(segvStack), nil) != 0:
      stderr.write("Warning: couldn't set SigSegv stack")
      stderr.flushFile()
    var action = Sigaction(
      sa_flags: bitor(SA_SIGINFO, SA_ONSTACK),
    )
    action.sa_sigaction = handler
    if sigaction(SIGSEGV, action, nil) != 0:
      stderr.write("Warning: couldn't set SigSegv handler")
      stderr.flushFile()

  macro addSegvHandler*(segvAddr, body: untyped): untyped =
    ## To use at top level
    let segvHandler = genSym(nskProc)
    quote do:
      proc `segvHandler`(signum: cint, info: ptr SigInfo, data: pointer) {.cdecl.} =
        let `segvAddr` = info[].si_addr
        `body`
        exitnow(1)
      
      addSegvHandlerHelper(`segvHandler`)


#[ ********* Memory Allocation ********* ]#

const DefaultStackSize: int = 4 * 1024 * 1024

when defined(windows):
  const StackSize* = DefaultStackSize
else:
  var SC_PHYS_PAGES {.importc: "_SC_PHYS_PAGES", header: "<unistd.h>".}: cint
  var MaxAvailableMemory = PageSize * sysconf(SC_PHYS_PAGES)
  var StackSize* = (
    if MaxAvailableMemory > 0:
      min(DefaultStackSize, (
        var res: int
        setBit(res, fastlog2(MaxAvailableMemory - 1))
        res
      )) ## For low memory systems
    else:
      DefaultStackSize
  )

# Not sure 16 KiB is enough for anythng, but better set a minimum limit
assert(StackSize > 16 * 1024, "NimGo can't work on system with very low RAM memory")  

when not NimGoNoDebug:
  var SegvWatcherMap: Table[pointer, pointer]

  proc recordProtectedBlock(allocatorData: pointer, memBlock: pointer) =
    ## memBlock corresponds to the full pointer, not the first aligned addr
    SegvWatcherMap[allocatorData] = memBlock

  proc unRecordProtectedBlock(allocatorData: pointer) =
    SegvWatcherMap.del(allocatorData)

  proc retrieveAllocatorDataFromSigsegv*(segvAddress: pointer): pointer =
    ## Complexity O(n), but not important at this point, because SIGSEGV is not recoeverable
    ## Maybe unsafe, GC might be triggered between SIGSEGV and signal handler
    let segvAddrInt = cast[int](segvAddress)
    for (allocatorData, memBlock) in pairs(SegvWatcherMap):
      let protectedPageStartInt = cast[int](getFirstAlignedAddr(memBlock))
      if segvAddrInt >= protectedPageStartInt and segvAddrInt < protectedPageStartInt + PageSize:
        return allocatorData
else:
  template recordProtectedBlock(allocatorData: pointer, memBlock: pointer) = discard
  template unRecordProtectedBlock(allocatorData: pointer) = discard
  proc retrieveAllocatorDataFromSigsegv*(segvAddress: pointer): pointer = nil

proc allocStack(): pointer =
  ## Stack has a safe guard page
  result = allocShared(StackSize) # allocShared0 worth it ?
  if not protectPointerBegin(result):
    deallocShared(result)
    raise newException(OsError, "Unable to set pageguard for stack end")

proc deallocStack(p: pointer) =
  if not unProtectPointerBegin(p):
    raise newException(OsError, "Unable to remove pageguard for stack end")
  deallocShared(p)

proc mcoStackAllocator*(size: uint, allocatorData: pointer): pointer {.cdecl.} =
  result = allocStack()
  recordProtectedBlock(allocatorData, result)

proc mcoStackDeallocator*(p: pointer, size: uint, allocatorData: pointer) {.cdecl.} =
  deallocStack(p)
  unRecordProtectedBlock(p)
