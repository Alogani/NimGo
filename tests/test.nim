type A = ref object of RootRef

type B = ref object of A

proc acceptA(a: A) =
    echo "accept"

var b = B()
acceptA(b)