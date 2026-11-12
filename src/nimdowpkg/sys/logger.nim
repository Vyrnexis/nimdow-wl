import
  os,
  logging,
  strutils,
  times

export logging

var
  logger: RollingFileLogger
  ## Opening the log file failed: not retried on every message.
  openFailed: bool
  enabled*: bool = false

proc writeLog(module, message: string, level: Level) =
  let line = "[$# $#][$#]: $#" % [getDateStr(), getClockStr(), module, message]
  echo "$# $#" % [LevelNames[level], line]

  if enabled:
    if logger == nil and not openFailed:
      try:
        logger = newRollingFileLogger(getHomeDir() & ".nimdow-wl.log", fmAppend)
      except:
        openFailed = true
        let err = getCurrentExceptionMsg()
        echo "Failed to open log file for logging:"
        echo err

    if logger != nil:
      logger.log(level, line)
      # Warnings and errors are flushed at once, so they survive a crash.
      if level >= lvlWarn:
        logger.file.flushFile()

template log*(message: string, level: Level = lvlInfo) =
  ## Debug messages are only formatted (the message is not even evaluated) and
  ## echoed while logging is enabled.
  if level != lvlDebug or enabled:
    const module = instantiationInfo().filename[0 .. ^5]
    writeLog(module, message, level)
