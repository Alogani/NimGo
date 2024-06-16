import std/[posix, oserrors]

import nimgo, nimgo/[goproc, gofile, gostreams]
import nimgo/private/childproc_posix
import os


proc openpty(masterFd, slaveFd: var cint; slaveFd_name: cstring; arg1,
        arg2: pointer): cint {.importc, header: "<pty.h>".}


type
  GoProcStream = ref object of GoBufferStream
    associatedFile: GoFile

proc newGoProcStream(file: GoFile): GoProcStream =
  result = GoProcStream(
    associatedFile: file,
  )
  procCall init(GoBufferStream(result))

method close*(s: GoProcStream) =
  procCall close(GoBufferStream(s))
  s.associatedFile.close()










proc main() =
  var ptyPairs = newPtyPair()
  var master = newGoFileStream(newGoFile(ptyPairs[0], fmReadWrite))
  var slave = newGoFile(ptyPairs[1], fmReadWrite)
  var slaveFd = slave.getOsFileHandle()

  var p = startProcess(Command(@["sh", "-c", "read a; echo BLAH"]),
    slave, slave, slave
  )

  discard close(slaveFd)
  var s = "42\n"
  discard write(master, s)

  var buffer = readAvailable(master, 4)
  if buffer == "":
    raiseOsError(osLastError())
  echo "Output: ", buffer

  var status: cint
  discard waitpid(Pid(p.getPid()), status, 0)
  echo "Return status: ", WEXITSTATUS(status)

  buffer = readAvailable(master, 1023)
  if buffer == "":
    raiseOsError(osLastError())
  echo "Output: ", buffer

goAndWait main()