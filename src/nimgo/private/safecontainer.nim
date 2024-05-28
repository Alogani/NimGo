# Some hideous code to trick GC to make traced reference safe in ARC (and by extension ORC)
# Fortunatly Araq will probably never see this and won't have a heart attack

type
    GcRefContainer[T] = ref object
        val: T

template mustGoInsideRef(T: typedesc): bool =
    # Non closures proc don't need to be stored inside ref, but simpler this way
    # String and seq needs to be contained, because Gc_ref doesn't exists for them anymore in ARC
    T is void or T is seq or T is string or T is proc

type
    SafeContainer*[T] = object
        when mustGoInsideRef(T):
            val: GcRefContainer[T]
        else:
            val: T

proc pushIntoContainer*[T](val: sink T): SafeContainer[T] =
    when T is ref:
        Gc_ref(val)
    elif mustGoInsideRef(T):
        let val = GcRefContainer[T](val: val)
        Gc_ref(val)
    return SafeContainer[T](val: val)

proc peek*[T](container: SafeContainer[T]): T =
    ## Does not free memory
    when T is ref:
        result = container.val
    elif mustGoInsideRef(T):
        let gcContainer = container.val
        result = gcContainer.val
    else:
        result = container.val

proc popFromContainer*[T](container: sink SafeContainer[T]): T =
    when T is ref:
        result = move(container.val)
        GC_unref(result)
    elif mustGoInsideRef(T):
        let gcContainer = move(container.val)
        Gc_unref(gcContainer)
        result = move(gcContainer.val)
    else:
        result = move(container.val)

proc isNil*[T](container: SafeContainer[T]): bool =
    when mustGoInsideRef(T):
        container.val == nil
    else:
        false

proc destroy*[T](container: SafeContainer[T]) =
    ## Not needed if toVal has been called. Won't double free if val is nil
    when mustGoInsideRef(T):
        if container.val != nil:
            GC_unref(container.val)
    else:
        discard
    