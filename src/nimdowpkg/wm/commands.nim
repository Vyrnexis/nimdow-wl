import
  options,
  strutils

export options

type
  WMCommand* = enum
    wmcReloadConfig = "reloadconfig",
    wmcIncreaseMasterCount = "increasemastercount",
    wmcDecreaseMasterCount = "decreasemastercount",
    wmcMoveWindowToPreviousMonitor = "movewindowtopreviousmonitor",
    wmcMoveWindowToNextMonitor = "movewindowtonextmonitor",
    wmcFocusPreviousMonitor = "focuspreviousmonitor",
    wmcFocusNextMonitor = "focusnextmonitor",
    wmcGoToTag = "gototag",
    wmcGoToLeftTag = "gotolefttag",
    wmcGoToRightTag = "gotorighttag",
    wmcGoToPreviousTag = "gotoprevioustag",
    wmcMoveWindowToPreviousTag = "movewindowtoprevioustag",
    wmcToggleTagView = "toggletagview",
    wmcToggleWindowTag = "togglewindowtag",
    wmcFocusNext = "focusnext",
    wmcFocusPrevious = "focusprevious",
    wmcMoveWindowPrevious = "movewindowprevious",
    wmcMoveWindowNext = "movewindownext",
    wmcMoveWindowToTag = "movewindowtotag",
    wmcMoveWindowToLeftTag = "movewindowtolefttag",
    wmcMoveWindowToRightTag = "movewindowtorighttag",
    wmcToggleFullscreen = "togglefullscreen",
    wmcDestroySelectedWindow = "destroyselectedwindow",
    wmcToggleFloating = "togglefloating",
    wmcMoveFloatingLeft = "movefloatingleft",
    wmcMoveFloatingDown = "movefloatingdown",
    wmcMoveFloatingUp = "movefloatingup",
    wmcMoveFloatingRight = "movefloatingright",
    wmcResizeFloatingNarrower = "resizefloatingnarrower",
    wmcResizeFloatingTaller = "resizefloatingtaller",
    wmcResizeFloatingShorter = "resizefloatingshorter",
    wmcResizeFloatingWider = "resizefloatingwider",
    wmcCenterFloating = "centerfloating",
    wmcJumpToUrgentWindow = "jumptourgentwindow"
    wmcIncreaseMasterWidth = "increasemasterwidth"
    wmcDecreaseMasterWidth = "decreasemasterwidth"
    wmcMoveWindowToScratchpad = "movewindowtoscratchpad"
    wmcPopScratchpad = "popscratchpad"
    wmcRotateclients = "rotateclients"
    wmcToggleStatusBar = "togglestatusbar"
    wmcStatus = "status"
    wmcDumpState = "dumpstate"
    wmcExitSession = "exitsession"
    wmcLockSession = "locksession"

proc parseCommand*(command: string): Option[WMCommand] =
  try:
    return some(parseEnum[WMCommand](command))
  except ValueError:
    return none[WMCommand]()

