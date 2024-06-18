import std/cpuinfo

const ThreadPoolSize {.intdefine.} = 0

proc getMaxThreads*(): int =
  if ThreadPoolSize > 0:
    return ThreadPoolSize
  else:
    return countProcessors()
  
