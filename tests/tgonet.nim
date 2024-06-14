when defined(windows):
  stderr.write("The features of these files hav enot yet been implemented under windows.\n")
  stderr.write("Skipping the test...\n")
  stderr.flushFile()
else:

  import nimgo, nimgo/gonet

  import std/unittest


  template ProducerConsumerCode(UseBuffer: bool) =
    ## Careful, sometime templates mess with tests
    const ServerPort = Port(12345)
    const ServerAddr = "127.0.0.1"

    proc consumer() =
      let client = newGoSocket(buffered = UseBuffer)
      client.connect(ServerAddr, ServerPort)
      check client.send("Hello\n") == 6
      check client.recvLine() == "How are you ?"
      check client.send("Fine\n") > 0
      client.close()

    ## Server code
    proc processClient(client: GoSocket) =
      check client.recv(10) == "Hello\n"
      check client.send("How are you ?\n") > 0
      check client.recv(10) == "Fine\n"
      check client.recv(10) == ""
      client.close()

    proc producer() =
      let server = newGoSocket(buffered = UseBuffer)
      server.setSockOpt(OptReuseAddr, true)
      server.bindAddr(ServerPort)
      server.listen()
      processClient(server.accept())
      server.close()

    withEventLoop():
      goAsync consumer()
      goAsync producer()

  test "Producer/consumer - unbuffered socket":
    ProducerConsumerCode(false)

  test "Producer/consumer - buffered socket":
    ProducerConsumerCode(true)
