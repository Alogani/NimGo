import asyncio
import std/times

var p1 = AsyncPipe.new()
var p2 = AsyncPipe.new()

var consumerSock = (receiver: p1.reader, sender: p2.writer)
var producerSock = (receiver: p2.reader, sender: p1.writer)

const NumberOfIO = 200

proc producer() {.async.} =
    while true:
        let t0 = cpuTime()
        for i in 0..<NumberOfIO:
            discard await producerSock.sender.write("Hello\n")
            discard await producerSock.receiver.readLine()
        let t1 = cpuTime() - t0
        echo "Number of operations: ", NumberOfIO
        echo "Average response time: ", t1
        await sleepAsync(300)

proc consummer() {.async.} =
    while true:
        discard await consumerSock.receiver.readLine()
        discard await consumerSock.sender.write("Hello\n")
    
discard consummer()
waitFor producer()
