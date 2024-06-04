import nimgo, nimgo/gonet
import std/[os, times, deques]

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
        
        waitAll(allClients)
        let t1 = cpuTime() - t0
        echo "Number of connections: ", NumberOfClients
        echo "Average response time: ", t1 / NumberOfClients
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
        let clientOpt = server.accept()
        if clientOpt.isNone():
            continue
        var client = clientOpt.get()
        clients.addLast client

withEventLoop():
    goAsync serve()
    goAsync client()