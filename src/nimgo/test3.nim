import ./public/gotasks
import ./eventdispatcher

proc main() =
    proc inner() =
        var data = "blah"
        goasync proc() =
            echo data
    inner()

withEventLoop:
    main()