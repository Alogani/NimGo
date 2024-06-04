import nimgo, nimgo/gofile
import std/times

## This test confirms that huge bottlenecks happens in the runDispatcher loop

import nimprof

const NumberOfIO = 200

const MaxRep = 10
var CurrentRep = 0

proc main() =
    var p1 = createGoPipe(buffered = false)
    var p2 = createGoPipe(buffered = false)
    var consumerSock = (receiver: p1[0], sender: p2[1])
    var producerSock = (receiver: p2[0], sender: p1[1])

    proc producer() =
        while CurrentRep < MaxRep:
            CurrentRep.inc()
            #let t0 = cpuTime()
            for i in 0..<NumberOfIO:
                discard producerSock.sender.write("Hello\n")
                discard producerSock.receiver.readLine()
            #let t1 = cpuTime() - t0
            #echo "Iteration num:", CurrentRep
            #echo "Number of operations: ", NumberOfIO
            #echo "Average response time: ", t1
            sleepAsync(300)

    proc consummer() =
        while true:
            discard consumerSock.receiver.readLine()
            discard consumerSock.sender.write("Hello\n")
        
    goAsync consummer()
    discard wait goAsync producer()
main()