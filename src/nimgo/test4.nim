import std/macros

proc main(): int =
    discard

macro print(t: typed): untyped =
    echo lispRepr(gettype(t))

print(proc() = echo "int")
print(main)