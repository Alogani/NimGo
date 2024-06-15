#[
    This bench shows a significant slower response time for nimgo:
        - x5 slower for unbuffered comparison
        - x1.8 slower for buffered comparison
    This bottleneck is unexpected, a reasonnable value should be less than 30% slower than asyncdispatch
    - It doesn't seem to come from the number of coroutines created, this has a negligible impact (tested with and without coroutinepool)
        -> to be exact, on my computer I have measured it to be responsible for 0,15% of the total time taken for the handling of the 200 clients
    - The overhead induced by coroutines context switch is also negligible for this number of coroutines
        -> to be exact, on my computer I have measured it to be responsible for 0,02% of the total time taken for the handling of the 200 clients
    
    So the bottleneck is elsewhere. To investigate:
        - if there is any unoticed busy waiting
        - the impact of the disseminated getRemainingMs()
        - flaws on the event loop design ?
        - the cost of wrapping std/net instead of using std/nativesockets
        - etc
]#

const NumberOfClients = 200
const UseBuffer = false


when defined(nimgo):
    import nimgo, nimgo/gonet
    import std/[os, times, deques]
    import nimgo/coroutines

    var clients: Deque[GoSocket]

    proc client() =
        var allClients = newSeq[GoTask[void]](NumberOfClients)
        while true:
            let t0 = cpuTime()
            for i in 0..<NumberOfClients:
                allClients[i] = go proc() =
                    let client = newGoSocket(buffered = UseBuffer)
                    client.connect("127.0.0.1", Port(12346))
                    discard client.send("Hello\n")
                    discard client.recvLine()
                    client.close()
            
            waitall allclients
            let t1 = cpuTime() - t0
            echo "Number of connections: ", NumberOfClients
            echo "Response time: ", t1
            sleepAsync(300)

    proc processClients() =
        while true:
            while clients.len() == 0:
                sleepAsync(300)
            let client = clients.popFirst()
            discard client.send("Hello\n")
            discard client.recvLine()
            client.close()

    proc serve() =
        var server = newGoSocket(buffered = UseBuffer)
        server.setSockOpt(OptReuseAddr, true)
        server.bindAddr(Port(12346))
        server.listen()
        go processClients()
        while true:
            let client = server.accept()
            clients.addLast client

    withEventLoop():
        go serve()
        go client()




else:
    import asyncnet, asyncdispatch
    import std/[os, times, deques]

    var clients: Deque[AsyncSocket]

    proc respondServer() {.async.} =
        let client = newAsyncSocket(buffered = UseBuffer)
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
            echo "Response time: ", t1
            await sleepAsync(300)

    proc processClients() {.async.} =
        while true:
            while clients.len() == 0:
                await sleepAsync(300)
            let client = clients.popFirst()
            discard client.send("Hello\n")
            discard client.recvLine()
            client.close()

    proc serve() {.async.} =
        var server = newAsyncSocket(buffered = UseBuffer)
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