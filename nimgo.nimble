# Package

version       = "0.0.7"
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

task genDocs, "Build the docs":
    ## importBuilder source code: https://github.com/Alogani/shellcmd-examples/blob/main/src/importbuilder.nim
    let githubUrl = "https://github.com/Alogani/asyncio"
    let bundlePath = "htmldocs/" & projectName() & ".nim"
    exec("./htmldocs/importbuilder --build src " & bundlePath & " --discardExports")
    exec("nim doc --git.url:" & githubUrl & " --git.commit:v" & $version & " --project --index:on --outdir:htmldocs " & bundlePath)

task genDocsAndPush, "genDocs -> git push":
    genDocsTask()
    exec("git add htmldocs")
    exec("git commit -m 'Update docs'")
    exec("git push")
