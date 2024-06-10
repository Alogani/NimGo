import nimgo, nimgo/gofile

import std/unittest


test "Producer/consumer":
    var (reader, writer) = createGoPipe()
    proc producer() =
        for i in 0..10:
            sleepAsync(10)
            writer.write("data" & $i)
        writer.close()

    proc consumer() =
        for i in 0..10:
            check reader.readChunk() == "data" & $i
        check reader.readChunk() == ""
        reader.close()

    withEventLoop:
        goAsync producer()
        goAsync consumer()
    check reader.closed()
    check writer.closed()
