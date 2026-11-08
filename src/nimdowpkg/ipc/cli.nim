import
  os,
  net,
  strutils,
  strformat,
  parseopt

import
  ipc,
  ../config/configloader,
  ../wmcommands,
  ../sys/logger

const version* = "v0.7.41"
const commit* = getEnv("LATEST_COMMIT")

proc handleWMCommand(commandStr: string): bool =
  ## Returns if the command was sent.
  var socket: Socket
  try:
    socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    let socketLoc = findSocketPath()
    socket.connectUnix(socketLoc)
  except CatchableError:
    log "Failed to connect to live socket: " & getCurrentExceptionMsg(), lvlError
    if socket != nil:
      socket.close()
    return false

  let message = fmt"{ipcPrefix} {commandStr}"
  let success = socket.trySend(message)
  if not success:
    log "Failed to send message to socket", lvlError

  socket.close()
  return success

proc handleSpecialCommand(strArr: seq[string]): bool =
  ## Returns if nimdow-wl execution should continue.
  if strArr.len < 1:
    return true

  case strArr[0]:
    of "v", "version":
      if commit.len > 0:
        echo fmt"nimdow-wl {version} - Commit {commit}"
      else:
        echo fmt"nimdow-wl {version}"
    of "c", "config":
      if strArr.len < 2:
        log "config needs a path: nimdow-wl --config <path>", lvlError
        return false
      configloader.configLoc = strArr[1]
      return true
    else:
      log "Unknown command", lvlError
      discard

proc handleCommandLineParams*(): bool =
  ## Executes actions based on cli params.
  ## Returns if nimdow-wl is intended to be ran normally.
  when not declared(commandLineParams):
    return true

  var p = initOptParser()
  var strArr: seq[string]

  while true:
    p.next()

    case p.kind:
      of cmdEnd: break
      of cmdShortOption, cmdLongOption, cmdArgument:
        # Only options carry leading dashes; arguments (paths, tag numbers) are kept as is.
        let option = if p.kind == cmdArgument: p.key else: p.key.replace("-")
        strArr.add option
        if p.val.len > 0:
          strArr.add p.val

  # The running instance has another working directory: send an absolute path.
  if strArr.len > 1 and strArr[0].toLowerAscii == "dumpstate":
    strArr[1] = absolutePath(strArr[1])

  if strArr.len == 0:
    return true

  let commandStr = strArr.join(" ")
  # The first param must be a valid command to be sent.
  if parseCommand(strArr[0].toLowerAscii).isSome:
    discard handleWMCommand(commandStr)
    return false
  return handleSpecialCommand(strArr)

