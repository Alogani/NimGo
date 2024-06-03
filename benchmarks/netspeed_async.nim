import asyncnet, asyncdispatch
import std/[os, times, deques]

const NumberOfClients = 200

var clients: Deque[AsyncSocket]

proc respondServer() {.async.} =
    let client = newAsyncSocket(buffered = false)
    await client.connect("127.0.0.1", Port(12346))
    discard client.send("Hello\n")
    discard client.recvLine()
    client.close()

proc client() {.async.} =
    var allClients = newSeq[Future[void]](NumberOfClients)
    while true:
        let t0 = cpuTime()
        for i in 0..<NumberOfClients:
            allClients[i] = respondServer()
        await all(allClients)
        let t1 = cpuTime() - t0
        echo "Number of connections: ", NumberOfClients
        echo "Average response time: ", t1
        await sleepAsync(300)

proc processClients() {.async.} =
    while true:
        while clients.len() == 0:
            await sleepAsync(300)
        let client = clients.popFirst()
        discard client.send("Hello\n")
        discard client.recvLine()

proc serve() {.async.} =
    var server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(12346))
    server.listen()
    asyncCheck processClients()
    while true:
        var client = await server.accept()
        clients.addLast client

asyncCheck serve()
asyncCheck client()
runForever()