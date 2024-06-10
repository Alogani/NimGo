import nimgo, nimgo/gostreams

import std/unittest


test "Producer/consumer":
    var s = newGoBufferStream()
    proc producer() =
        for i in 0..10:
            sleepAsync(10)
            s.write("data" & $i)
        s.close()

    proc consumer() =
        for i in 0..10:
            check s.readChunk() == "data" & $i
        check s.readChunk() == ""

    withEventLoop:
        goAsync producer()
        goAsync consumer()

test "Timeout":
    var s = newGoBufferStream()
    check (goAndWait s.readChunk(10)) == ""