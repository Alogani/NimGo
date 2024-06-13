when defined(release):
  const NimGoNoDebug* = true
else:
  const NimGoNoDebug* {.booldefine.} = false