import aloganimisc/fasttest

const Rep = 100000

type MyObject = object
  val1: int
  val2: int

var G: int

proc handle(o: var MyObject) =
  G.inc(o.val1)
  G.inc(o.val2)

runBench():
  block:
    var val1 = 42
    var val2 = 43
    for i in 0..Rep:
      var o = MyObject(val1: val1, val2: val2)
      handle(o)

echo G

runBench():
  block:
    var val1 = 42
    var val2 = 43 
    for i in 0..Rep:
      var cb = proc() =
        G.inc val1
        G.inc(val2)
      cb()

echo G