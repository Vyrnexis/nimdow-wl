import
  std/[os],
  parsetoml

import
  types,
  outputs,
  windows,
  actions,
  debug,
  seats,
  sequence,
  ../bar/statusbar,
  ../tray/traymenu,
  ../config/configloader,
  ../wl/client as wlclient,
  ../wl/protocols/[river_window_management_v1, river_xkb_bindings_v1, river_layer_shell_v1],
  ../sys/logger

export wlclient
export types.WindowManager, types.markDirty
export outputs.setStatus, outputs.startTray
export actions.applyConfig, actions.reloadConfig, actions.mapConfigActions, actions.runIpcAction,
  actions.destroySelectedWindow
export debug.dumpState
export sequence.timerTimeoutMs, sequence.fireTimers

## The River window manager.
##
## River is double buffered: event handlers and actions only mutate nimdow's own
## state (Client, Monitor, TaggedClients). The state is flushed to River in
##  - `manage_start`: show/hide, propose_dimensions, focus_window, close,
##    binding setup; ends with `manage_finish`.
##  - `render_start`: set_position, set_borders, stacking; ends with
##    `render_finish`.
## Actions invoked outside of a manage sequence (IPC) call `markDirty` so River
## starts a manage sequence.

# ---------------------------------------------------------------------------
# Window manager global
# ---------------------------------------------------------------------------

proc wmUnavailable(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  stderr.writeLine "error: another window manager is already running"
  quit(1)

proc wmFinished(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  quit(0)

proc wmManageStart(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  wm.onManageStart()

proc wmRenderStart(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  wm.onRenderStart()

var wmListener = river_window_manager_v1_noop_listener()
wmListener.unavailable = wmUnavailable
wmListener.finished = wmFinished
wmListener.manage_start = wmManageStart
wmListener.render_start = wmRenderStart
wmListener.window = wmWindow
wmListener.output = wmOutput
wmListener.seat = wmSeat

proc newWindowManager*(config: Config, configTable: TomlTable): WindowManager =
  ## Connects to River and binds the window management globals.
  ## Raises an IOError when River (or a required global) is unavailable.
  result = WindowManager(config: config, sortedDirty: true)
  wm = result

  # Config first: it enables the logger, so what follows is logged.
  try:
    result.applyConfig(config, configTable)
  except Exception:
    logger.enabled = config.loggingEnabled
    log getCurrentExceptionMsg(), lvlError

  result.display = connect()
  if result.display.isNil:
    raise newException(IOError, "failed to connect to the Wayland server")

  # Avoid passing WAYLAND_DEBUG on to our children.
  delEnv("WAYLAND_DEBUG")

  let registry = discoverGlobals(result.display)
  let wmGlobal = registry.find("river_window_manager_v1")
  let xkbGlobal = registry.find("river_xkb_bindings_v1")
  if wmGlobal.version >= 4:
    result.manager = bindGlobal[RiverWindowManagerV1](
      registry, wmGlobal, river_window_manager_v1_interface, 4
    )
  if xkbGlobal.version >= 1:
    result.xkbBindings = bindGlobal[RiverXkbBindingsV1](
      registry, xkbGlobal, river_xkb_bindings_v1_interface, 1
    )
  let layerGlobal = registry.find("river_layer_shell_v1")
  if layerGlobal.version >= 1:
    result.layerShell = bindGlobal[RiverLayerShellV1](
      registry, layerGlobal, river_layer_shell_v1_interface, 1
    )
  else:
    log "river_layer_shell_v1 not available: layer surfaces will not work", lvlWarn
  if result.manager.isNil or result.xkbBindings.isNil:
    raise newException(
      IOError,
      "river_window_manager_v1 or river_xkb_bindings_v1 not supported by the Wayland server"
    )

  result.barCtx = newBarContext(registry, result.manager)
  if result.barCtx == nil:
    log "wl_compositor/wl_shm not available: the status bar is disabled", lvlWarn
  else:
    result.barCtx.requestManage = proc() = wm.markDirty()
    result.menu = newMenuManager(result.barCtx)

  discard river_window_manager_v1_add_listener(result.manager, addr wmListener, nil)
  # Receive the initial globals (outputs, seats) before the event loop starts.
  discard result.display.roundtrip()
