import ./eventdispatcher
import ./public/gotasks

proc inner() =
    echo "sleep"
    sleepAsync(1000)
    echo "wake up"

proc main() =
    discard wait goAsync inner()

discard wait goAsync main()