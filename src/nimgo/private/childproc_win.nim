{.error: "Not implemnted".}

import std/[posix, os, oserrors]
import std/[tables, strutils]

type
    ChildProc* = ref object


proc startProcessWin*(command: string, args: seq[string],
            stdin = FileHandle(-1), stdout = FileHandle(-1), stderr = FileHandle(-1);
            cwd = "", env = initTable[string, string]();
            creationflags = 0'i32
        ): ChildProc =
    discard
    