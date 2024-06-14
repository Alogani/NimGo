import std/[times, monotimes]

type
  TimeOutWatcher* = object
    finishAt: MonoTime
    hasNoDeadline: bool
    isExpired: bool

proc initTimeoutWatcher*(timeoutMs: int): TimeOutWatcher =
  TimeOutWatcher(
    finishAt: (
      if timeoutMs != -1:
        getMonoTime() + initDuration(milliseconds = timeoutMs)
      else:
        MonoTime()),
    hasNoDeadline: if timeoutMs == -1: true else: false
  )

proc timeoutWatcherFromFinishAt*(finishAt: MonoTime): TimeOutWatcher =
  TimeOutWatcher(
    finishAt: finishAt,
    hasNoDeadline: false
  )

func `<=`*(a, b: TimeOutWatcher): bool =
  if a.hasNoDeadline:
    return false
  elif b.hasNoDeadline:
    return true
  else:
    a.finishAt < b.finishAt

func hasNoDeadline*(self: TimeOutWatcher): bool =
  return self.hasNoDeadline

proc expired*(self: var TimeOutWatcher): bool =
  if self.hasNoDeadline:
    return false
  if self.isExpired:
    return true
  else:
    if (self.finishAt - getMonoTime()).inMilliseconds() < 0:
      self.isExpired = true
      return true
    else:
      return false

proc getRemainingMs*(self: var TimeOutWatcher): int =
  if self.hasNoDeadline:
    return -1
  if self.isExpired:
    return 0
  let remaining = (self.finishAt - getMonoTime()).inMilliseconds()
  if remaining < 0:
    self.isExpired = true
    return 0
  else:
    return remaining

func clampTimeout*(x, b: int): int =
  ## if b == -1, consider it infinity
  ## Minimum timeout is always 0
  if x < 0: return 0
  if b != -1 and x > b: return b
  return x
