import nimgo, nimgo/gonet
import std/[os, times, deques]

#[
    This test shows a very slow time for handling new clients (x100 slower than async) for now
    It has not been identified where the bottlenecks is
]#

const NumberOfClients = 200

var clients: Deque[GoSocket]

withEventLoop():
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
            
            discard waitAll(allClients)
            let t1 = cpuTime() - t0
            echo "Number of connections: ", NumberOfClients
            echo "Average response time: ", t1
            sleepAsync(300)

    proc processClients() =
        while true:
            while clients.len() == 0:
                sleepAsync(300)
            let client = clients.popFirst()
            discard client.send("Hello\n")
            discard client.recvLine()

    proc serve() =
        var server = newGoSocket(buffered = false)
        server.setSockOpt(OptReuseAddr, true)
        server.bindAddr(Port(12346))
        server.listen()
        goAsync processClients()
        while true:
            var client = server.accept().get()
            clients.addLast client

    goAsync serve()
    goAsync client()