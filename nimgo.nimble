# Package

version       = "0.0.1"
author        = "alogani"
description   = "Asynchronous Library Inspired by Go's goroutines"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0.2"


task reinstall, "Reinstalls this package":
    var path = "~/.nimble/pkgs2/" & projectName() & "-*"
    exec("rm -rf " & path)
    exec("nimble install")