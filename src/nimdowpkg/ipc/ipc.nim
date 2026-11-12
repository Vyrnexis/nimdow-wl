import
  os,
  net,
  nativesockets,
  strutils,
  strformat,
  times

from posix import kill, errno, recv, poll, TPollfd, Pid, ESRCH, EINTR, EAGAIN, POLLIN,
  stat, Stat, mkdir, getuid, S_IRWXU, EEXIST, Mode

import ../sys/logger

const
  ipcPrefix* = "nimdow-ipc"
  socketPrefix = "ipc-socket."
  ## Longest accepted IPC message.
  MaxMessageLength = 64 * 1024
  ## A client that is silent for this long is dropped (milliseconds).
  ClientTimeoutMs = 20

let
  ## Without XDG_RUNTIME_DIR the sockets live in a private directory of /tmp.
  privateDir = not existsEnv("XDG_RUNTIME_DIR")
  socketDir =
    if privateDir: fmt"/tmp/nimdow-wl-{getuid()}"
    else: getEnv("XDG_RUNTIME_DIR") & "/nimdow-wl"
  pid = getCurrentProcessId()
  socketLoc* = fmt"{socketDir}/{socketPrefix}{pid}"

proc socketPid(filePath: string): int =
  ## The PID in the name of an `ipc-socket.<pid>` file; -1 for other files.
  let name = extractFilename(filePath)
  if not name.startsWith(socketPrefix):
    return -1
  try:
    result = parseInt(name[socketPrefix.len .. ^1])
  except ValueError:
    result = -1

proc isAlive(pid: int): bool =
  ## Whether a process with this PID exists (EPERM: it does, but is not ours).
  pid > 0 and (kill(pid.Pid, 0) == 0 or errno != ESRCH)

proc checkSocketDir() =
  ## The /tmp directory must be ours and closed to others (anybody could have
  ## created it first). Raises OSError.
  if not privateDir:
    return
  var st: Stat
  if stat(socketDir.cstring, st) != 0 or st.st_uid != getuid() or (st.st_mode.int and 0o077) != 0:
    raise newException(OSError, socketDir & " is not a private directory of this user")

proc findSocketPath*(): string =
  ## The socket of the running instance (the newest, if there are several).
  checkSocketDir()
  var newest: times.Time
  for kind, filePath in walkDir(socketDir):
    let socketOwner = socketPid(filePath)
    if kind != pcFile or socketOwner < 0 or not socketOwner.isAlive():
      continue
    try:
      let modified = getLastModificationTime(filePath)
      if result.len == 0 or modified > newest:
        result = filePath
        newest = modified
    except OSError:
      discard

proc deleteOldIPCSockets() =
  ## Removes the sockets of instances that are no longer running.
  for kind, filePath in walkDir(socketDir):
    let socketOwner = socketPid(filePath)
    if kind == pcFile and socketOwner >= 0 and not socketOwner.isAlive():
      discard tryRemoveFile(filePath)
  # A leftover of an earlier process that had our PID.
  discard tryRemoveFile(socketLoc)

proc initIPCSocket*(): Socket =
  ## Creates and initializes a non-blocking socket at socketLoc.
  ## This proc can raise an Exception.
  if mkdir(socketDir.cstring, Mode(S_IRWXU)) != 0 and errno != EEXIST:
    raiseOSError(osLastError())
  checkSocketDir()
  deleteOldIPCSockets()

  result = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  result.bindUnix(socketLoc)
  result.listen()
  # accept() must never block the event loop.
  result.getFd().setBlocking(false)
  log fmt"Created ipc socket: {socketLoc}"

proc recvMessage*(client: Socket): string =
  ## Reads a client's message until it closes the connection, with a size and a
  ## time limit so a stalled client cannot freeze the window manager. Returns ""
  ## on a timeout, an overflow or an error: a truncated message must not run.
  let
    fd = client.getFd()
    deadline = epochTime() + ClientTimeoutMs / 1000
  fd.setBlocking(false)
  var
    message: string
    buffer: array[4096, char]
  while message.len < MaxMessageLength:
    let received = recv(fd, addr buffer[0], buffer.len, 0)
    if received > 0:
      let start = message.len
      message.setLen(start + received)
      copyMem(addr message[start], addr buffer[0], received)
    elif received == 0:
      return message
    elif errno == EINTR:
      continue
    elif errno == EAGAIN:
      let remaining = int((deadline - epochTime()) * 1000)
      if remaining <= 0:
        return ""
      var pfd = TPollfd(fd: fd.cint, events: POLLIN)
      if poll(addr pfd, 1, remaining.cint) <= 0:
        return ""
    else:
      return ""
