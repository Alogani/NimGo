import nimgo, nimgo/gofile


let MyFilePath = currentSourcePath()

## # Basic I/O
proc readAndPrint(file: GoFile) =
    # readAndPrint will be suspended until file.readLine return
    echo "MYLINE=", file.readLine()
    # file.readAll will be registered in dispatcher. readAndPrint can continue its execution
    var readTask: GoTask[string] = goAsync file.readAll()
    # we decide finally to get its data
    # readAndPrint will be suspended until readTask is finished
    echo "UNREADLENGTH=", (wait readTask).len()

block:
    var myFile = openGoFile(MyFilePath)
    withEventLoop():
        goAsync readAndPrint(myFile)
        echo "I'm not waiting for readAndPrint to finish !"
    echo "But `withEventLoop` ensures all registered tasks are executed"
    myFile.close()

## # Coroutines communication

## ## Returning a value:
block:
    proc getFirstLine(f: GoFile): string =
        f.readLine()
    var myFile = openGoFile(MyFilePath)
    echo "MYLINE=", wait goAsync getFirstLine(myFile)
    myFile.close()

## ## With closures:
proc main() =
    # Any GC value can be shared between coroutines
    var sharedData: string
    ## We have to use wait, otherwise sharedData will not be updated yet
    wait goAsync proc() =
        sharedData = "Inside the coroutine"
    echo sharedData
withEventLoop():
    main()


## # Unordered execution

proc printInDesorder(sleepTimeMs: int) =
    sleepAsync(sleepTimeMs)
    echo "> I woke up after ", sleepTimeMs, "ms"

withEventLoop():
    echo "Batch 1"
    goAsync printInDesorder(200)
    goAsync printInDesorder(100)
    goAsync printInDesorder(50)
# Or using waitAll
echo "Batch 2"
waitAll @[
    goAsync printInDesorder(110),
    goAsync printInDesorder(220),
    goAsync printInDesorder(60),
]

## Timeout

wait goAsync proc() =
    echo "Please input from stdin: "
    var data = goStdin.readChunk(timeoutMs = 500)
    if data.len() == 0:
        echo "> Too late"
    else:
        echo "> So fast, you have succesfully written: ", data
