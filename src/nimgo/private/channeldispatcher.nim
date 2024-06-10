## General idea:
## Thread queue of the available channels that have data into it
## hashmap to the coroutines to wake up when there are data into it
## But how to avoid going back to the dispatcher each time ?
## With a flag to control ownership ? but data race