import
  std/exitprocs,
  std/posix,
  os,
  net,
  selectors,
  strutils,
  strformat

import
  nimdowpkg/windowmanager,
  nimdowpkg/tray/tray,
  nimdowpkg/config/configloader,
  nimdowpkg/ipc/cli,
  nimdowpkg/ipc/ipc,
  nimdowpkg/wmcommands,
  nimdowpkg/sys/spawn,
  nimdowpkg/sys/session,
  nimdowpkg/sys/logger

proc handleCommand(str: string, windowmanager: WindowManager) =
  ## Runs the action for an IPC message: `nimdow-ipc <command> [argument]`.
  ## The argument (e.g. a tag number for `goToTag`) is passed as the key.
  ## It is everything after the command, whitespace included (a status text,
  ## a path).
  let split = str.split(' ', maxsplit = 2)
  if split.len < 2:
    log "Not enough arguments.", lvlWarn
    return

  if split[0] != ipcPrefix:
    log fmt"Commands must be prefixed with {ipcPrefix}", lvlWarn
    return

  let
    command = split[1].toLower()
    arg = if split.len > 2: split[2] else: ""
  if command == $wmcStatus:
    if windowmanager.setStatus(arg):
      windowmanager.markDirty()
    return

  if parseCommand(command).isSome:
    windowmanager.runIpcAction(command, arg)

proc fatal(msg: string) =
  stderr.writeLine msg
  quit(1)

var
  quitRequested = false
  ## Write end of the pipe that wakes the event loop on SIGTERM/SIGINT.
  quitPipeWrite: cint = -1

proc onQuitSignal(sig: cint) {.noconv.} =
  ## Async-signal-safe: sets a flag and writes a byte to the self-pipe.
  quitRequested = true
  var byte = 1'u8
  discard write(quitPipeWrite, addr byte, 1)

proc installQuitHandlers(): cint =
  ## Makes SIGTERM and SIGINT end the event loop (so the exit procs run).
  ## Returns the read end of the self-pipe.
  var fds: array[2, cint]
  if pipe(fds) != 0:
    return -1
  for fd in fds:
    discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  quitPipeWrite = fds[1]
  var sa: Sigaction
  sa.sa_handler = onQuitSignal
  discard sigemptyset(sa.sa_mask)
  discard sigaction(SIGTERM, sa)
  discard sigaction(SIGINT, sa)
  return fds[0]

when isMainModule:
  if not cli.handleCommandLineParams():
    quit()

  let loadedConfig = newConfig()

  # Falls back to the built-in default config if the user's file is broken.
  let configTable = loadConfigFile()

  # Reap spawned processes (autostart and key bindings).
  installChildReaper()
  let quitFd = installQuitHandlers()

  var nimdow: WindowManager
  try:
    nimdow = newWindowManager(loadedConfig, configTable)
  except CatchableError:
    fatal getCurrentExceptionMsg()

  addExitProc(proc() =
    discard tryRemoveFile(ipc.socketLoc)
    stopSession()
  )

  log "Starting nimdow-wl " & version

  # Export the display to systemd/D-Bus and start XDG autostart.
  startSession()

  nimdow.startTray()

  try:
    loadedConfig.runAutostartCommands(configTable)
  except Exception:
    log getCurrentExceptionMsg(), lvlError

  let
    selector = newSelector[int]()
    display = nimdow.display
    displayFd = display.fd().int
    ipcSocket = ipc.initIPCSocket()
    ipcSocketFd = ipcSocket.getFd().int

  selector.registerHandle(displayFd, {Event.Read}, 0)
  selector.registerHandle(ipcSocketFd, {Event.Read}, 1)
  if quitFd >= 0:
    selector.registerHandle(quitFd.int, {Event.Read}, 3)

  # What each handle is registered for (the selector is only told about changes).
  var
    displayWanted: set[Event] = {Event.Read}
    # The tray's D-Bus connection (-1 while it is not registered with the selector).
    trayFd = -1
    trayWanted: set[Event]

  while not quitRequested:
    # Standard libwayland read protocol: dispatch whatever is queued, flush our
    # requests, wait for the sockets, then read and dispatch.
    prepareRead(display)

    var flushed = true
    if display.flush() < 0:
      if errno != EAGAIN:
        display.cancelRead()
        fatal "flush failed"
      flushed = false
    let displayInterest =
      if flushed: {Event.Read} else: {Event.Read, Event.Write}
    if displayInterest != displayWanted:
      selector.updateHandle(displayFd, displayInterest)
      displayWanted = displayInterest

    # The D-Bus connection: wait for what sd-bus asks for, wake up for its
    # timeouts and for the tray's debounced refetches.
    var timeout = -1
    let tray = nimdow.tray
    if tray != nil and tray.alive:
      let events = tray.events()
      var wanted: set[Event] = {Event.Read}
      if (events and POLLOUT.int) != 0: wanted.incl Event.Write
      if trayFd < 0:
        trayFd = tray.fd()
        selector.registerHandle(trayFd, wanted, 2)
        trayWanted = wanted
      elif wanted != trayWanted:
        selector.updateHandle(trayFd, wanted)
        trayWanted = wanted
      timeout = tray.timeoutMs()
    elif trayFd >= 0:
      try:
        selector.unregister(trayFd)
      except CatchableError:
        # The connection (and its fd) is already closed.
        discard
      trayFd = -1

    let menuTimeout = nimdow.timerTimeoutMs()
    if menuTimeout >= 0 and (timeout < 0 or menuTimeout < timeout):
      timeout = menuTimeout

    var displayReadable, ipcReadable = false
    for event in selector.select(timeout):
      if event.fd == displayFd:
        if Event.Read in event.events or Event.Error in event.events:
          displayReadable = true
      elif event.fd == ipcSocketFd:
        ipcReadable = true
      elif event.fd == quitFd.int:
        quitRequested = true

    if displayReadable:
      if display.readEvents() < 0: fatal "failed to read Wayland events"
    else:
      display.cancelRead()

    if ipcReadable:
      var client: Socket
      try:
        ipcSocket.accept(client, flags = {})
      except CatchableError:
        # The client went away (or nothing is pending after all).
        client = nil
      if client != nil:
        try:
          let received = client.recvMessage()
          handleCommand(received, nimdow)
        except CatchableError:
          log "IPC command failed: " & getCurrentExceptionMsg(), lvlError
        finally:
          client.close()

    # Always processed (not only when readable): sd-bus may have queued
    # messages or timeouts, and due refetches run here. Never blocks.
    if tray != nil and tray.alive:
      tray.process()

    nimdow.fireTimers()

    if display.dispatchPending() < 0: fatal "failed to dispatch Wayland events"

  log "Shutting down"
  quit(0)
