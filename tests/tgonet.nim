import nimgo, nimgo/gonet
import os

var clients: seq[GoSocket]

withEventLoop():
    proc client() =
        let client = newGoSocket()
        client.connect("127.0.0.1", Port(12346))
        while true:
            let data = client.recv(10, timeoutMs = 10)
            echo "data=", data

    proc serve() =
        var server = newGoSocket()
        server.setSockOpt(OptReuseAddr, true)
        server.bindAddr(Port(12345))
        server.listen()
        var (address, client) = server.acceptAddr().get()
        echo "Client connected from:", address
        var i = 0
        while true:
            discard client.send("data" & $i)
            i += 1
            echo "sleep"
            sleepAsync(1000)
            echo "wake up"

    goAsync serve()
    goAsync client()