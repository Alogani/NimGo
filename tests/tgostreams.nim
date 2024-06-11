import nimgo, nimgo/[gofile, gostreams]

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

test "Producer/consumer with GoFileStream on top of pipes":
    var pipes = createGoPipe(buffered = true)
    var reader = newGoFileStream(pipes.reader)
    let writer = newGoFileStream(pipes.writer)
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
