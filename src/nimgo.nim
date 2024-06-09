import ./nimgo/[eventdispatcher]

# from eventdispatcher, which are the only functions useful for normal users
export sleepAsync, insideNewEventLoop, withEventLoop, runEventLoop, newDispatcher, setCurrentThreadDispatcher

import ./nimgo/public/gotasks
export gotasks