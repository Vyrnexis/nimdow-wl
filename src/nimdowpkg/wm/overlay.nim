import
  std/tables,
  types,
  monitor,
  ../bar/overlay as baroverlay,
  ../bar/statusbar,
  ../config/configloader

## The hotkey overlay (see bar/overlay.nim): this opens and closes it, keeps it
## on the monitor that was selected when it was opened and hands it the
## config. Escape closes it too (a binding enabled only while it is open,
## see seats.nim).

proc closeOverlay*(this: WindowManager) =
  if this.overlay != nil:
    this.overlay.close()
  this.overlayMonitor = nil

proc openOverlay(this: WindowManager) =
  if this.overlay == nil or this.selectedMonitor == nil:
    return
  let monitor = this.selectedMonitor
  this.overlayMonitor = monitor
  this.overlay.open(if monitor.statusBar != nil: monitor.statusBar.scale120 else: 120)
  this.overlay.setContent(this.config, monitor.monitorSettings.barSettings)

proc toggleOverlay*(this: WindowManager) =
  if this.overlayOpen: this.closeOverlay() else: this.openOverlay()

proc manageOverlay*(this: WindowManager) =
  ## Closes the overlay when it was clicked, the session locked or its monitor
  ## went away, shows it at startup if configured and follows config reloads.
  ## Manage sequence only.
  if this.overlay == nil:
    return
  if not this.overlayStartupDone and this.selectedMonitor != nil:
    this.overlayStartupDone = true
    if this.config.hotkeyOverlayAtStartup:
      this.openOverlay()
  if this.overlayOpen:
    if this.overlay.clicked or this.locked or
        this.monitors.getOrDefault(this.overlayMonitor.id) != this.overlayMonitor:
      this.closeOverlay()
    elif this.overlay.config != this.config:
      this.overlay.setContent(this.config, this.overlayMonitor.monitorSettings.barSettings)

proc flushOverlay*(this: WindowManager) =
  ## Render sequence only.
  if this.overlayOpen:
    let area = this.overlayMonitor.area
    this.overlay.flush(area.x, area.y, area.width.int, area.height.int)
