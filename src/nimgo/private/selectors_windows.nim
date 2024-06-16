import std/oserrors
import std/winlean
import ./utils

type
  Selector* = distinct Handle

  AsyncFd = distinct Handle

const NumberOfConcurrentThreads = 1 # 0 means as many processors as in the system

proc newSelector*(): Selector =
  result = Selector(createIoCompletionPort(
    INVALID_HANDLE_VALUE,
    0,
    0,
    1
  ))

proc registerHandleImpl(selector: Selector, fd: AsyncFd, fdData: pointer) =
  ## The handle must be to an object that supports overlapped I/O.
  if createIoCompletionPort(
        fd.Handle,
        selector.Handle,
        cast[ULONG_PTR](fdData),
        NumberOfConcurrentThreads,
      ) == 0:
    raiseOSError(osLastError())

proc select(selector: Selector, timeoutMs: int): tuple[fd: AsyncFd, customData: pointer] =
  # bytesTransfered permit to tell us how many bytes were read/written
  # we are able to inherit ptr OVERLAPPED to pack supplemntary data
  var winTimeout = (
    if timeoutMs == -1:
      winlean.INFINITE
    else:
      timeoutMs.int32)
  var bytesTransfered: DWORD
  var fdData: pointer
  var overlappedPtr: ptr OVERLAPPED # what to do this it ?
  let success = bool(getQueuedCompletionStatus(
    selector.Handle,
    addr(bytesTransfered),
    cast[PULONG_PTR](addr(fdData)),
    addr(overlappedPtr),
    winTimeout
    ))
  ## TODO dealloc overlappedPtr
  if not success:
    if overlappedPtr == nil:
      # What does it mean ?
      discard #?
    else:
      let osError = osLastError()
      if osError.int32 == WAIT_TIMEOUT:
        discard #?
      else:
        dealloc(overlappedPtr)
        raiseOSError(osError)

proc registerReadFile*(selector: Selector, fd: AsyncFd, customData: pointer, buffer: pointer, size: int, bytesRead: ptr int, cancellation: out proc()) =
  var customOverlappedPtr = allocAndSet(CustomOverlapped(customData: customData, bytesReadPtr: bytesRead)) # overlapped must be zeroed
  var overlappedPtr = cast[ptr OVERLAPPED](customOverlappedPtr) # this is what std/asyncdispatch do
  let success = bool(readFile(fd.Handle, buffer, size.int32, nil, overlappedPtr))
  if not success:
    let osError = osLastError()
    if osError.int32 == ERROR_HANDLE_EOF:
      # TODO: Add it inside the selector queue
      discard # For now
    else:
      dealloc(customOverlappedPtr)
      raiseOSError(osError)
  cancellation = proc() = cancel(selector, overlappedPtr)
    

proc readFile(fd: AsyncFd, buffer: var string, size: int, timeoutMs = -1) =
  ## This is only an example usage:
  buffer = newString(size)
  # Here we pass coroutine by simplicity, but we could pass a more complex object
  var customData = cast[pointer](getCurrentCoroutine())
  var bytesRead: int
  var cancellationCb: proc()
  registerReadFile(ActiveSelector, fd, customData, addr(result[0]), size, addr(bytesRead), cancellationCb)
  if timeoutMs != -1:
    registerTimerExecution(cancellationCb, timeoutMs)
  suspend()
  buffer.setLen(bytesRead)


proc loop(selector: Selector) =
  var fd: Handle
  select(selector, -1, fd, )
#[
proc registerConnect*(selector: Selector)

proc registerWriteFile*(selector: Selector)

proc registerSendMsg*(selector: Selector)

proc registerSendTo*(selector: Selector)

proc regisrerSend*(selector: Selector)

proc registerRecvFrom*(selector: Selector)

proc registerRecv*(selector: Selector)
]#