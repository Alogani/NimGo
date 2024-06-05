#[
    Tested on commit number 25, with Fedora OS

    This benchmarks shows a largely better performance for nimgo.
    Performance was even better when buffered to avoid reading one character at a time for readline.
    This is unexpected, because of the time of the context switch induced by coroutines. The reason is probably because asyncdispatcher use a seq instead of a queue
    The memory usage were the sames for the two programs due to the few coroutines needed.
]#

when defined(nimgo):
    import nimgo, nimgo/gofile
    import std/times

    const NumberOfIO = 1000

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
                let t0 = cpuTime()
                for i in 0..<NumberOfIO:
                    discard producerSock.sender.write("Hello\n")
                    discard producerSock.receiver.readLine()
                let t1 = cpuTime() - t0
                echo "Iteration num:", CurrentRep
                echo "Number of operations: ", NumberOfIO
                echo "Average response time: ", t1
                sleepAsync(300)

        proc consummer() =
            while true:
                discard consumerSock.receiver.readLine()
                discard consumerSock.sender.write("Hello\n")
            
        goAsync consummer()
        wait goAsync producer()
    main()

    echo "Total mem=", getTotalMem()
    echo "Shared mem=", getTotalSharedMem()

else: # Async
    import asyncio
    import std/times

    var p1 = AsyncPipe.new()
    var p2 = AsyncPipe.new()

    var consumerSock = (receiver: p1.reader, sender: p2.writer)
    var producerSock = (receiver: p2.reader, sender: p1.writer)

    const NumberOfIO = 1000

    const MaxRep = 10
    var CurrentRep = 0

    proc producer() {.async.} =
        while CurrentRep < MaxRep:
            CurrentRep.inc()
            let t0 = cpuTime()
            for i in 0..<NumberOfIO:
                discard await producerSock.sender.write("Hello\n")
                discard await producerSock.receiver.readLine()
            let t1 = cpuTime() - t0
            echo "Iteration num:", CurrentRep
            echo "Number of operations: ", NumberOfIO
            echo "Average response time: ", t1
            await sleepAsync(300)

    proc consummer() {.async.} =
        while true:
            discard await consumerSock.receiver.readLine()
            discard await consumerSock.sender.write("Hello\n")
        
    discard consummer()
    waitFor producer()

    echo "Total mem=", getTotalMem()
    echo "Shared mem=", getTotalSharedMem()