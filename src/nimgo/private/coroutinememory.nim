import std/[bitops, oserrors]

#const VirtualStackSize: uint = 2 * 1024 * 1024 # 2 MB should be more than enough
const VirtualStackSize: uint = 16000 # 2 MB should be more than enough

var McoStackSize*: uint
proc mcoAllocator*(size: uint, allocatorData: pointer): pointer {.cdecl.}
proc mcoDeallocator*(p: pointer, size: uint, allocatorData: pointer) {.cdecl.}


when defined(windows):
    ## Not tested on windows
    import std/winlean

    McoStackSize = VirtualStackSize

    var MEM_COMMIT {.importc: "MEM_COMMIT", header: "<memoryapi.h>".}: cint
    var MEM_RESERVE {.importc: "MEM_RESERVE", header: "<memoryapi.h>".}: cint
    var MEM_RELEASE {.importc: "MEM_RESERVE", header: "<memoryapi.h>".}: cint

    proc VirtualAlloc(lpAddress: pointer, dwSize: uint, flAllocationType, flProtect: cint): pointer {.importc: "VirtualAlloc", header: "<memoryapi.h>".}
    proc VirtualFree(lpAdress: pointer, dwSize: uint, dwFreeType: cint): bool {.importc: "VirtualFree", header: "<memoryapi.h>".}
    proc VirtualProtect(lpAddress: pointer, dwSize: uint, flNewProtect: cint, lpflOldProect: var cint): bool {.importc: "VirtualProtect", header: "<memoryapi.h>".}

    proc mcoDeallocator*(p: pointer, size: uint, allocatorData: pointer) {.cdecl.} =
        if not VirtualFree(p, 0, MEM_RELEASE):
            raiseOSError(osLastError())

    proc mcoAllocator*(size: uint, allocatorData: pointer): pointer {.cdecl.} =
        ## On windows, we will always use virtual memory
        result = VirtualAlloc(nil, size, bitor(MEM_COMMIT, MEM_RESERVE), PAGE_READWRITE)
        if result == nil:
            raiseOSError(osLastError())
        var oldProtect: cint
        if not VirtualProtect(c, 0x1000, PAGE_NOACCESS, oldProtect):
            mcoDeallocator(result, size, nil)
            raiseOSError(osLastError())

else:
    import std/posix

    var SC_PHYS_PAGES {.importc: "_SC_PHYS_PAGES", header: "<unistd.h>".}: cint

    const NimGoNoVMem* {.booldefine.} = false
    const PhysicalMemPageCount {.intdefine.} = 16 ## 64 Kib on system with 4096 page size
    let PageSize = sysconf(SC_PAGESIZE)
    var AvailableMemory = PageSize * sysconf(SC_PHYS_PAGES)
        # This doesn't take in account swap size
    var UsePhysicalMemory = NimGoNoVMem or AvailableMemory < VirtualStackSize.int

    if UsePhysicalMemory:
        McoStackSize = PhysicalMemPageCount * SC_PAGESIZE.uint
    else:
        McoStackSize = VirtualStackSize

    proc mcoDeallocator*(p: pointer, size: uint, allocatorData: pointer) {.cdecl.} =
        if UsePhysicalMemory:
            dealloc(p)
        else:
            if munmap(p, size.int) != 0:
                raiseOSError(osLastError())

    proc mcoAllocator*(size: uint, allocatorData: pointer): pointer {.cdecl.} =
        if UsePhysicalMemory:
            result = alloc0(size)
        else:
            result = mmap(nil, size.int,
                bitor(PROT_READ, PROT_WRITE),
                bitor(MAP_PRIVATE, MAP_ANONYMOUS),
                -1, 0
            )
            if result == MAP_FAILED:
                raiseOSError(osLastError())
        
        if mprotect(ourProtection, SC_PAGESIZE, PROT_NONE) != 0:
            ## Stack begins at its bottom
            mcoDeallocator(result, size, nil)
            raiseOSError(osLastError())
        