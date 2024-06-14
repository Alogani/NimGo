when defined(windows):
    stderr.write("The features of these files hav enot yet been implemented under windows.\n")
    stderr.write("Skipping the test...\n")
    stderr.flushFile()
    quit(0)

import nimgo, nimgo/gofile

import std/unittest


template ProducerConsumerCode(UseBuffer: bool) =
    ## Careful, sometime templates mess with tests
    var (reader, writer) = createGoPipe(buffered = UseBuffer)
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

test "Producer/consumer - unbuffered pipe":
    ProducerConsumerCode(false)

test "Producer/consumer - buffered pipe":
    ProducerConsumerCode(true)