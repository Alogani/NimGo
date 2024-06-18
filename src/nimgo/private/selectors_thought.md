Sorry to make again another update about this, but I have continue some research about how IOCP internally works, how epoll handle multithreadings, etc, etc. Done some micro benchmarks (as much as it worth), thought again about the design, etc.

And I have come to some conclusions.

### Facts
Those must be nuanced, but for the sake of simplicity, I won't nuance them. I'll talk about EPOLL because I know it and have searched about it better, but hoses considerations might apply more or less to its alike SELECT, POLL, KQUEUE. Metrics has to be taken with a grain of salt and have been done in microbenchmarks on my computer.

- IOCP use a completion design. It is less flexible, but modern and efficient
- EPOLL uses a reactor design (based on readiness). It is flexible, but harder to use well
- It is not possible to emulate EPOLL with IOCP
- It is possible to emulate IOCP with EPOLL
- IOCP is by nature multithreaded at the OS level (this can be tweaked) and will adjust the number of threads up to the number of processors according to workload. Those threads handle the whole I/O operation (waiting its readiness, making the I/O operation and returning it to a thread queue). It is not clear if those threads are inside or outside the program, but it doesn't matter much.
- EPOLL is hard to make multithreading right
- std/selectors doesn't allow EPOLLET flag that is one that could allow efficient shared EPOLL selectors across threads
- EPOLL have a significant overhead for one system call, but this overhead is amortized by the number of registered selectors:
  - 0,8 μs / epoll_wait with 1 registered handle
  - 160 μs / epoll_wait with 40K registered handle
- I/O on a ready available Handle have an overhead close to an empty epoll_wait (0,8 μs / read or write for less than 20 chars)
- channel message passing is quite free when no lock is involved
  - 20 ns/operation for std/channels [int] (copy)
  - 40 ns/operation for threading/channels [int] (isolates)
  - 30 ns/operation for linked list [int] (no locks, copy) https://github.com/Alogani/NimGo_multithreadingattempt/blob/main/src/nimgo/private/threadqueue.nim


### Based on those reflexions:
- Having a shared EPOLL is not worth it. Many bottlenecks would happen outside the wait. Only the following case would be inefficiently handled : high throughtput on a single handle. (Please note IOCP certainly distributes work better)
- It would be hard to emulate IOCP without directly implementing EPOLL in a dedicated thread
- The actual I/O operation will be the bottleneck in most situations, so delegating the actual read/write to another thread will have a performance benefit
- So the ideal design will be a dedicated thread for the wait and worker threads for the actual I/O operation. This design would be simple enough to ensure safety, scalability, emulate IOCP design closely.
- Additionally, the workload could be adjusted:
  - on low workload, the epoll_wait and io completion thread could be the same
  - on high workload, a thread poll could be created and manage threads up to processor count. There will still be only one thread that issue epoll_wait, this thread will also have the task to handle the workpoll and distributes work.
  - This design is probably very close to IOCP
- It would also make a clear distinction between I/O threads and CPU threads, allowing maximum efficiency (just like IOCP)
- This design reponds some questions of #21
- This design could allow to leverage more easily existing solutions of threading pools (status-im/nim-taskpools, weave, malebolgia)

For now the IO worker pool won't be implemented, and will be added later. (only one worker thread for EPOLL)

### API proposition
The public API of the private IOCP and std/selectors wrapper would still be very close to what was proposed.
For reference (using pseudo code) :

```nim
## Globally
var s = newSelector()
spawnSelectorLoop()

## Main thread

```