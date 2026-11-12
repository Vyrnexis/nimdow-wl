## The built-in status bar: a `river_shell_surface_v1` per monitor, drawn with
## cairo + pango into a double-buffered wl_shm pool.
##
## Input: the shell surface receives wl_pointer events directly on our own
## connection (we bind wl_seat and its pointer). Button presses and scrolls over
## a bar are queued in `BarContext.clicks` and handled by the window manager in
## the next manage sequence (a manage sequence is requested via
## `requestManage`, since pointer events do not start one by themselves).
##
## All bar commits happen in `flush`, which must only be called during a manage
## or render sequence (the commit is synchronised with `sync_next_commit`).
##
## Scale: with wp_fractional_scale_v1 + wp_viewporter the buffer is rendered at
## the physical size and the viewport destination is the logical size. Without
## them the integer wl_surface.preferred_buffer_scale is used with
## set_buffer_scale. Drawing code always works in logical units (the cairo
## surface has a device scale).
##
## A cursor image (wayland-cursor, XCURSOR_THEME/XCURSOR_SIZE) is set while the
## pointer is over a bar.

import
  std/[tables, math],
  types,
  fonts,
  input,
  render,
  ../config/configloader,
  ../config/tagsettings,
  ../wl/client as wlclient,
  ../wl/cairo,
  ../wl/cursor,
  ../wl/shm,
  ../tray/tray,
  ../wl/protocols/[river_window_management_v1, viewporter, fractional_scale_v1]

export types.BarTag, types.FontSet, types.StatusBar, types.TrayRegion, types.ClickedRegion,
  types.BarClick, types.InputTarget, types.BarContext
export input.newBarContext, input.scale120
export fonts.primary, fonts.newLayout, fonts.textSize
export render.regionAt

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newStatusBar*(
  ctx: BarContext,
  settings: BarSettings,
  tagSettings: TagSettings
): StatusBar =
  result = StatusBar(
    ctx: ctx, settings: settings, tagLabels: tagLabels(tagSettings),
    metricsGen: -1, metricsScale: -1
  )
  result.wanted.trayVersion = -1
  result.drawn.trayVersion = -1
  GC_ref result
  let bar = result
  result.scaled = newScaledSurface(
    ctx.compositor, ctx.viewporter, ctx.fractionalManager, 120,
    proc() =
      # Redrawn in the next manage sequence.
      if ctx.requestManage != nil:
        ctx.requestManage()
  )
  result.pool = newShmPool(ctx.shm, "nimdow-bar", proc() =
    if ctx.requestManage != nil:
      ctx.requestManage()
  )
  result.shell = river_window_manager_v1_get_shell_surface(ctx.manager, result.scaled.surface)
  result.node = river_shell_surface_v1_get_node(result.shell)
  result.fonts = ctx.fontSetFor(settings.fonts)
  ctx.bars.add bar

proc destroy*(ctx: BarContext) =
  ## Releases the cursor surface and themes. The bars must be destroyed first;
  ## the context must not be used afterwards.
  for theme in ctx.cursorThemes.values:
    if theme != nil:
      wl_cursor_theme_destroy(theme)
  ctx.cursorThemes.clear()
  if ctx.cursorSurface != nil:
    wl_surface_destroy(ctx.cursorSurface)
    ctx.cursorSurface = nil

proc removeTarget*(ctx: BarContext, target: InputTarget) =
  ## Stops routing pointer events to the target (its surface is going away).
  let index = ctx.targets.find(target)
  if index >= 0:
    ctx.targets.delete index
  for pointer in ctx.pointers:
    if pointer.target == target:
      pointer.target = nil

proc destroy*(this: StatusBar) =
  ## Releases the bar's Wayland objects. The bar must not be used afterwards.
  for pointer in this.ctx.pointers:
    if pointer.focus == this:
      pointer.focus = nil
  var i = 0
  while i < this.ctx.clicks.len:
    if this.ctx.clicks[i].bar == this:
      this.ctx.clicks.delete i
    else:
      inc i
  let index = this.ctx.bars.find(this)
  if index >= 0:
    this.ctx.bars.delete index
  if this.layout != nil:
    g_object_unref(this.layout)
  this.pool.destroy()
  river_node_v1_destroy(this.node)
  river_shell_surface_v1_destroy(this.shell)
  this.scaled.destroy()
  GC_unref this

proc setConfig*(this: StatusBar, settings: BarSettings, tagSettings: TagSettings) =
  this.settings = settings
  this.tagLabels = tagLabels(tagSettings)
  this.fonts = this.ctx.fontSetFor(settings.fonts)
  inc this.wanted.configGen

proc height*(this: StatusBar): int = this.settings.height.int

proc barSettings*(this: StatusBar): BarSettings = this.settings

proc fontSet*(this: StatusBar): FontSet =
  ## The bar's fonts (shared; keep the reference to keep using them).
  this.fonts

proc origin*(this: StatusBar): tuple[x, y: int] = (this.originX, this.originY)

proc update*(this: StatusBar, tags: openArray[BarTag], title: string, monitorSelected: bool) =
  ## Sets what the bar shows for tags and the focused window; drawn by `flush`.
  ## Only writes what differs.
  if this.wanted.tags.len != tags.len:
    this.wanted.tags.setLen tags.len
  for i, tag in tags:
    if this.wanted.tags[i] != tag:
      this.wanted.tags[i] = tag
  if this.wanted.title != title:
    this.wanted.title = title
  this.wanted.monitorSelected = monitorSelected

proc setTray*(this: StatusBar, tray: Tray) =
  ## Shows the tray on this bar (nil: no tray here).
  this.tray = tray
  this.wanted.trayVersion = if tray != nil: tray.version else: -1

iterator trayLayout*(this: StatusBar): TrayRegion =
  ## The icons of the last draw, with x relative to the screen.
  for region in this.trayRegions:
    var r = region
    r.x += this.originX
    yield r

proc trayIconAt*(this: StatusBar, x, y: int): tuple[uid, x, y: int] =
  ## The tray icon under the surface position (uid -1: none), with the icon's
  ## position on the screen.
  result = (-1, 0, 0)
  for region in this.trayRegions:
    if x >= region.x and x < region.x + region.width and y >= 0 and y < this.wanted.height:
      return (region.uid, this.originX + region.x,
        this.originY + (this.wanted.height - region.width) div 2)

proc tagCount*(this: StatusBar): int = this.tagLabels.len

# ---------------------------------------------------------------------------
# Committing
# ---------------------------------------------------------------------------

proc flush*(this: StatusBar, x, y, width: int, visible: bool) =
  ## Positions the bar's node and, if anything changed, redraws and commits it.
  ## Only valid during a manage or render sequence.
  river_node_v1_set_position(this.node, x.int32, y.int32)
  this.originX = x
  this.originY = y

  this.wanted.width = width
  this.wanted.height = this.settings.height.int
  this.wanted.scale120 = this.scale120
  this.wanted.visible = visible and width > 0 and this.settings.height > 0

  if not this.wanted.visible:
    this.trayRegions.setLen 0
    if this.drawn.visible:
      # Unmap the bar.
      river_shell_surface_v1_sync_next_commit(this.shell)
      wl_surface_attach(this.scaled.surface, nil, 0, 0)
      wl_surface_commit(this.scaled.surface)
    this.drawn = this.wanted
    return

  if this.wanted == this.drawn:
    return

  let
    pixelWidth = this.scaled.physical(width)
    pixelHeight = this.scaled.physical(this.wanted.height)
  if not this.pool.resize(pixelWidth, pixelHeight):
    # Allocation failed (logged). `drawn` stays stale, so the next flush tries
    # again; no manage sequence is requested here.
    return
  let index = this.pool.acquire()
  if index == -1:
    # Both buffers are still held by the compositor; the pool asks for a new
    # manage sequence once one is released.
    return
  this.draw(this.pool.data(index))
  this.scaled.prepare(width, this.wanted.height)
  river_shell_surface_v1_sync_next_commit(this.shell)
  this.pool.present(index, this.scaled.surface)
  this.drawn = this.wanted
