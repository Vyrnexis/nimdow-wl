import
  std/[strutils, tables, os, math],
  types,
  ../wl/client as wlclient,
  ../wl/cairo,
  ../wl/cursor,
  ../wl/shm,
  ../wl/protocols/[river_window_management_v1, viewporter, fractional_scale_v1]

const
  btnLeft = 0x110'u32
  btnRight = 0x111'u32
  btnMiddle = 0x112'u32
  ## X11 style button numbers, as passed to the click region commands.
  buttonLeft = 1
  buttonMiddle = 2
  buttonRight = 3
  buttonScrollUp = 4
  buttonScrollDown = 5
  scrollThreshold = 10.0
  ## wl_pointer.axis_value120 units of one wheel notch.
  wheelNotch = 120
  ## wl_pointer versions that send frame/axis_stop and axis_value120.
  pointerFrameVersion = 5'u32
  pointerValue120Version = 8'u32
  seatVersion = 8'u32

# ---------------------------------------------------------------------------
# Wayland globals: compositor, shm, seats/pointers
# ---------------------------------------------------------------------------

proc setCursor(p: BarPointer, serial: uint32, scale: int) =
  ## Shows the default cursor of the theme named by XCURSOR_THEME/XCURSOR_SIZE.
  let ctx = p.ctx
  if ctx.cursorSurface == nil:
    ctx.cursorSurface = wl_compositor_create_surface(ctx.compositor)
  if scale notin ctx.cursorThemes:
    # Loaded once per scale (nil when the theme cannot be loaded).
    let
      themeName = getEnv("XCURSOR_THEME")
      size = try: parseInt(getEnv("XCURSOR_SIZE", "24")) except ValueError: 24
    ctx.cursorThemes[scale] = wl_cursor_theme_load(
      if themeName.len > 0: themeName.cstring else: nil,
      (max(size, 1) * scale).cint,
      ctx.shm
    )
  let theme = ctx.cursorThemes[scale]
  if theme == nil:
    return
  var cursor = wl_cursor_theme_get_cursor(theme, "default")
  if cursor == nil:
    cursor = wl_cursor_theme_get_cursor(theme, "left_ptr")
  if cursor == nil or cursor.imageCount == 0:
    return
  let
    image = cursor.images[0]
    buffer = wl_cursor_image_get_buffer(image)
  if buffer.isNil:
    return
  wl_surface_set_buffer_scale(ctx.cursorSurface, scale.int32)
  wl_surface_attach(ctx.cursorSurface, buffer, 0, 0)
  wl_surface_damage_buffer(ctx.cursorSurface, 0, 0, image.width.int32, image.height.int32)
  wl_surface_commit(ctx.cursorSurface)
  wl_pointer_set_cursor(
    p.obj, serial, ctx.cursorSurface,
    (image.hotspotX.int div scale).int32, (image.hotspotY.int div scale).int32
  )

proc scale120*(this: StatusBar): int = this.scaled.scale120

proc resetScroll(p: BarPointer) =
  p.axisAcc = 0
  p.wheelAcc = 0
  p.frameAxis = 0
  p.frameWheel = 0
  p.frameHasWheel = false

proc pointerEnter(data: pointer, obj: WlPointer, serial: uint32, surface: WlSurface,
    x, y: WlFixed) {.cdecl.} =
  let p = cast[BarPointer](data)
  p.focus = nil
  p.target = nil
  p.x = wlFixedToFloat(x).int
  p.y = wlFixedToFloat(y).int
  p.resetScroll()
  if not surface.isNil:
    for target in p.ctx.targets:
      if target.surface == surface:
        p.target = target
        p.setCursor(serial, max(1, (target.scale120 + 119) div 120))
        if target.enter != nil:
          target.enter(p.x, p.y)
        return
    for bar in p.ctx.bars:
      if bar.scaled.surface == surface:
        p.focus = bar
        p.setCursor(serial, max(1, (bar.scale120 + 119) div 120))
        if p.ctx.barHover != nil:
          p.ctx.barHover(bar, p.x, p.y)
        return

proc pointerLeave(data: pointer, obj: WlPointer, serial: uint32,
    surface: WlSurface) {.cdecl.} =
  let p = cast[BarPointer](data)
  if p.focus != nil and p.ctx.barLeave != nil:
    p.ctx.barLeave()
  p.focus = nil
  let target = p.target
  p.target = nil
  if target != nil and target.leave != nil:
    target.leave()

proc pointerMotion(data: pointer, obj: WlPointer, time: uint32, x, y: WlFixed) {.cdecl.} =
  let p = cast[BarPointer](data)
  p.x = wlFixedToFloat(x).int
  p.y = wlFixedToFloat(y).int
  if p.target != nil and p.target.motion != nil:
    p.target.motion(p.x, p.y)
  elif p.focus != nil and p.ctx.barHover != nil:
    p.ctx.barHover(p.focus, p.x, p.y)

proc queueClick(p: BarPointer, button: int) =
  if p.target != nil:
    if p.target.button != nil:
      p.target.button(button, p.x, p.y)
    return
  if p.focus == nil:
    return
  p.ctx.clicks.add BarClick(bar: p.focus, x: p.x, y: p.y, button: button)
  if p.ctx.requestManage != nil:
    p.ctx.requestManage()

proc pointerButton(data: pointer, obj: WlPointer, serial, time, button,
    state: uint32) {.cdecl.} =
  if state != WL_POINTER_BUTTON_STATE_PRESSED:
    return
  let x11Button =
    case button
    of btnLeft: buttonLeft
    of btnMiddle: buttonMiddle
    of btnRight: buttonRight
    else: 0
  if x11Button != 0:
    queueClick(cast[BarPointer](data), x11Button)

proc scrollSteps(p: BarPointer) =
  ## Queues the scroll clicks of what accumulated so far. Wheel notches
  ## (axis_value120) count 120 per click; everything else (touchpads, wheels of
  ## compositors without value120) is the accumulated axis value, a click per
  ## `scrollThreshold`.
  if p.frameHasWheel:
    p.wheelAcc += p.frameWheel
    while p.wheelAcc <= -wheelNotch:
      p.wheelAcc += wheelNotch
      queueClick(p, buttonScrollUp)
    while p.wheelAcc >= wheelNotch:
      p.wheelAcc -= wheelNotch
      queueClick(p, buttonScrollDown)
  else:
    p.axisAcc += p.frameAxis
    if p.axisAcc <= -scrollThreshold:
      p.axisAcc = 0
      queueClick(p, buttonScrollUp)
    elif p.axisAcc >= scrollThreshold:
      p.axisAcc = 0
      queueClick(p, buttonScrollDown)
  p.frameAxis = 0
  p.frameWheel = 0
  p.frameHasWheel = false

proc pointerAxis(data: pointer, obj: WlPointer, time: uint32, axis: uint32,
    value: WlFixed) {.cdecl.} =
  if axis != WL_POINTER_AXIS_VERTICAL_SCROLL:
    return
  let p = cast[BarPointer](data)
  p.frameAxis += wlFixedToFloat(value)
  if p.version < pointerFrameVersion:
    # No frame events: handle every event on its own.
    p.scrollSteps()

proc pointerAxisValue120(data: pointer, obj: WlPointer, axis: uint32,
    value120: int32) {.cdecl.} =
  if axis != WL_POINTER_AXIS_VERTICAL_SCROLL:
    return
  let p = cast[BarPointer](data)
  p.frameWheel += value120.int
  p.frameHasWheel = true

proc pointerAxisStop(data: pointer, obj: WlPointer, time: uint32, axis: uint32) {.cdecl.} =
  ## The scroll gesture ended: what is left of it must not count toward the next.
  if axis != WL_POINTER_AXIS_VERTICAL_SCROLL:
    return
  let p = cast[BarPointer](data)
  p.axisAcc = 0
  p.wheelAcc = 0

proc pointerFrame(data: pointer, obj: WlPointer) {.cdecl.} =
  let p = cast[BarPointer](data)
  p.scrollSteps()

var pointerListener = wl_pointer_noop_listener()
pointerListener.enter = pointerEnter
pointerListener.leave = pointerLeave
pointerListener.motion = pointerMotion
pointerListener.button = pointerButton
pointerListener.axis = pointerAxis
pointerListener.axis_value120 = pointerAxisValue120
pointerListener.axis_stop = pointerAxisStop
pointerListener.frame = pointerFrame

type SeatData = ref object
  ctx: BarContext
  seat: WlSeat
  pointer: BarPointer
  keyboard: WlKeyboard

proc seatCapabilities(data: pointer, seat: WlSeat, caps: uint32) {.cdecl.} =
  let s = cast[SeatData](data)
  if (caps and WL_SEAT_CAPABILITY_POINTER) != 0 and s.pointer == nil:
    let p = BarPointer(ctx: s.ctx, obj: wl_seat_get_pointer(seat))
    p.version = wl_proxy_get_version(cast[ptr WlProxy](p.obj))
    GC_ref p
    discard wl_pointer_add_listener(p.obj, addr pointerListener, cast[pointer](p))
    s.pointer = p
    s.ctx.pointers.add p
  elif (caps and WL_SEAT_CAPABILITY_POINTER) == 0 and s.pointer != nil:
    s.ctx.pointers.delete s.ctx.pointers.find(s.pointer)
    wl_pointer_release(s.pointer.obj)
    GC_unref s.pointer
    s.pointer = nil
  if (caps and WL_SEAT_CAPABILITY_KEYBOARD) != 0 and s.keyboard.isNil:
    s.keyboard = wl_seat_get_keyboard(seat)
    if s.ctx.onKeyboard != nil:
      s.ctx.onKeyboard(s.keyboard)
  elif (caps and WL_SEAT_CAPABILITY_KEYBOARD) == 0 and not s.keyboard.isNil:
    wl_keyboard_release(s.keyboard)
    s.keyboard = nil

var seatListener = wl_seat_noop_listener()
seatListener.capabilities = seatCapabilities

proc bindSeat(ctx: BarContext, registry: Registry, global: Global) =
  let s = SeatData(ctx: ctx)
  GC_ref s
  s.seat = bindGlobal[WlSeat](registry, global, wl_seat_interface, seatVersion)
  discard wl_seat_add_listener(s.seat, addr seatListener, cast[pointer](s))

proc newBarContext*(registry: Registry, manager: RiverWindowManagerV1): BarContext =
  ## Binds wl_compositor, wl_shm and all wl_seats. Returns nil when the
  ## compositor or shm is missing (the bar is then unavailable).
  let
    compositorGlobal = registry.find("wl_compositor")
    shmGlobal = registry.find("wl_shm")
  if compositorGlobal.version < 4 or shmGlobal.version < 1:
    return nil
  result = BarContext(manager: manager)
  # Version 6 adds wl_surface.preferred_buffer_scale.
  result.compositor = bindGlobal[WlCompositor](
    registry, compositorGlobal, wl_compositor_interface, 6
  )
  result.shm = bindGlobal[WlShm](registry, shmGlobal, wl_shm_interface, 1)
  let
    viewporterGlobal = registry.find("wp_viewporter")
    fractionalGlobal = registry.find("wp_fractional_scale_manager_v1")
  if viewporterGlobal.version >= 1 and fractionalGlobal.version >= 1:
    result.viewporter = bindGlobal[WpViewporter](
      registry, viewporterGlobal, wp_viewporter_interface, 1
    )
    result.fractionalManager = bindGlobal[WpFractionalScaleManagerV1](
      registry, fractionalGlobal, wp_fractional_scale_manager_v1_interface, 1
    )
  for global in registry.globals:
    if global.iface == "wl_seat":
      result.bindSeat(registry, global)
  # Seats added later get the pointer handling too.
  let ctx = result
  registry.onGlobal = proc(global: Global) =
    if global.iface == "wl_seat":
      ctx.bindSeat(registry, global)
