# Source: https://github.com/nim-lang/threading/blob/master/threading/smartptrs.nim
# With small tweaks
# This doesn't use isolates, so uniqueness is not guaranted by the compiler

import std/atomics
export atomics

#[*** Helpers ***]#

template checkNotNil*(p: pointer) =
    when compileOption("boundChecks"):
        {.line.}:
            if p == nil:
                raise newException(ValueError, "Attempt to read from nil")

proc allocSharedAndSet*[T](val: sink T): ptr T {.nodestroy.} =
    ## More efficient than allocShared0 and still safe
    result = cast[ptr T](allocShared(sizeof T))
    result[] = move(val)

proc newAtomic*[T](val: sink T): Atomic[T] =
    result.store(val, moRelaxed)

#[ *** API *** ]#

type
    SharedPtr*[T] = object
        ## Thread safe shared ownership reference counting pointer.
        ## However multiple threads can mutate at the same time the val
        ## Usage of a Lock or `SharedResource` can prevent that
        val: ptr tuple[value: T, counter: Atomic[int]]

proc decr[T](p: SharedPtr[T]) {.inline.} =
    {.cast(raises: []).}:
        if p.val != nil:
            # this `fetchSub` returns current val then subs
            # so count == 0 means we're the last
            if p.val.counter.fetchSub(1, moAcquireRelease) == 0:
                `=destroy`(p.val.value)
                deallocShared(p.val)
                addr(p.val)[] = nil

proc `=destroy`*[T](p: SharedPtr[T]) {.nodestroy.} =
    p.decr()

proc `=dup`*[T](src: SharedPtr[T]): SharedPtr[T] =
    if src.val != nil:
        discard fetchAdd(src.val.counter, 1, moRelaxed)
    result.val = src.val

proc `=copy`*[T](dest: var SharedPtr[T], src: SharedPtr[T]) =
    if src.val != nil:
        discard fetchAdd(src.val.counter, 1, moRelaxed)
    if dest.val != nil:
        `=destroy`(dest)
    dest.val = src.val

proc newSharedPtr*[T](val: sink T): SharedPtr[T] {.nodestroy.} =
    ## Returns a zero initialized shared pointer
    result.val = allocSharedAndSet[(T, Atomic[int])](
        (val, newAtomic(0))
    )

proc isNil*[T](p: SharedPtr[T]): bool {.inline.} =
    p.val == nil

proc `[]`*[T](p: SharedPtr[T]): var T {.inline.} =
    p.val.value

proc `[]=`*[T](p: SharedPtr[T], val: sink T) {.inline.} =
    p.val.value = val

proc getUnsafePtr*[T](p: SharedPtr[T]): pointer =
    ## Get the pointer not of T, but directly of SharedPtr (including the ref count)
    ## Will not decrement the ref count. But giving it back with toSharedPtr will increment the ref count
    ## Unsafe: nothing prevents pointer to be freed. Only use case is to store a circular reference
    ## Can be used in conjonction with `toSharedPtr`
    cast[pointer](p.val)

proc toSharedPtr*[T](t: typedesc[T], p: pointer): SharedPtr[T] =
    ## The pointer agument should have been obtained by getUnsafePtr
    ## Will increment the reference count, which is normally safe because we have created a copy of SharedPtr without passing by `=copy`
    var pVal = cast[ptr (T, Atomic[int])](p)
    result = SharedPtr[T](val: pVal)
    if p != nil:
        result.val[].counter.atomicInc()

type
    SharedPtrNoCopy*[T] = object
        p: SharedPtr[T]

proc disableCopy*[T](p: SharedPtr[T]): SharedPtrNoCopy[T] =
    SharedPtrNoCopy[T](p: p)

proc `=dup`*[T](src: SharedPtrNoCopy[T]): SharedPtrNoCopy[T] {.error.}

proc `=copy`*[T](dest: var SharedPtrNoCopy[T], src: SharedPtrNoCopy[T]) {.error.}

proc isNil*[T](p: SharedPtrNoCopy[T]): bool {.inline.} =
    isNil(p.p)

proc `[]`*[T](p: SharedPtrNoCopy[T]): var T {.inline.} =
    `[]`(p.p)

proc `[]=`*[T](p: SharedPtrNoCopy[T], val: sink T) {.inline.} =
    `[]=`(p.p)

template checkNotNil*[T](p: SharedPtr[T]) =
    when compileOption("boundChecks"):
        {.line.}:
            if p.isNil():
                raise newException(ValueError, "Attempt to read from nil")
