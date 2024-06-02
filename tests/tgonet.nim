import nimgo, nimgo/io/gonet
import os

var clients: seq[GoSocket]

withEventLoop():
    proc client() =
        let client = newGoSocket()
        discard client.connect("127.0.0.1", Port(12345))
        while true:
            let data = client.recv(10)
            echo "data=", data

    proc serve() =
        var server = newGoSocket()
        server.setSockOpt(OptReuseAddr, true)
        server.bindAddr(Port(12345))
        server.listen()
        var (address, client) = server.acceptAddr()
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