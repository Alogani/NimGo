proc allocAndSet*[T](val: sink T): ptr T {.nodestroy.} =
  ## More efficient than allocShared0 and still safe
  result = cast[ptr T](alloc(sizeof T))
  result[] = move(val)