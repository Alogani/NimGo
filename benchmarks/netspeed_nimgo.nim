import nimgo, nimgo/gonet
import std/[os, times, deques]
import nimgo/coroutines
#[
    This bench shows a very slow time for handling new clients (x10 slower than async) for now
    This bottleneck is unexpected, a reasonnable value should be less than 30% slower than asyncdispatch
    - It doesn't seem to come from the number of coroutines created, this has a negligible impact (tested with and without coroutinepool)
        -> to be exact, on my computer I have measured it to be responsible for 0,15% of the total time taken for the handling of the 200 clients
    - The overhead induced by coroutines context switch is also negligible for this number of coroutines
        -> to be exact, on my computer I have measured it to be responsible for 0,02% of the total time taken for the handling of the 200 clients
    So the bottleneck is elsewhere
]#

const NumberOfClients = 200

var clients: Deque[GoSocket]


proc client() =
    var allClients = newSeq[GoTask[void]](NumberOfClients)
    while true:
        let t0 = cpuTime()
        for i in 0..<NumberOfClients:
            allClients[i] = goAsync proc() =
                let client = newGoSocket(buffered = false)
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
    var server = newGoSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(12346))
    server.listen()
    goAsync processClients()
    while true:
        let client = server.accept()
        clients.addLast client

withEventLoop():
    goAsync serve()
    goAsync client()