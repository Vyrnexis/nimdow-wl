import
  std/[json, options, posix],
  ../config/configloader,
  ../sys/logger,
  ../wl/client,
  ../wl/protocols/[river_input_management_v1, river_xkb_config_v1, river_libinput_config_v1]

## Keyboard (keymap, repeat, numlock) and libinput (touchpad, mouse) settings of
## the `[input]` config section. None of these requests needs a manage sequence.
##
## River's input devices are three kinds of objects linked by `input_device`
## events: the `river_input_device_v1` (type, repeat), the `river_xkb_keyboard_v1`
## and the `river_libinput_device_v1`. A `Device` holds them together. Settings
## are applied when a device is complete (the `done` events), when the keymap is
## ready and on config reload. An unset setting is never sent.

type
  XkbRuleNames {.importc: "struct xkb_rule_names", header: "<xkbcommon/xkbcommon.h>".} = object
    rules, model, layout, variant, options: cstring

proc xkb_context_new(flags: cint): pointer {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_new_from_names(
  ctx: pointer, names: ptr XkbRuleNames, flags: cint
): pointer {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_get_as_string(keymap: pointer, format: cint): cstring {.
  importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_unref(keymap: pointer) {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc memfd_create(name: cstring, flags: cuint): cint {.importc, header: "<sys/mman.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc wl_proxy_destroy(proxy: pointer) {.importc, cdecl.}

const
  MfdCloexec = 1.cuint
  MfdAllowSealing = 2.cuint
  FAddSeals = 1033.cint
  AllSeals = 15.cint ## F_SEAL_SEAL | SHRINK | GROW | WRITE
  # River's defaults, for the one of repeatRate/repeatDelay that is not set.
  DefaultRepeatRate = 25
  DefaultRepeatDelay = 600

type
  ## The libinput features a device supports and its current values (-1: unknown).
  Libinput = object
    tapFingers, natural, leftHanded, dwt: int32
    profiles, clickMethods, scrollMethods: uint32
    tap, naturalScroll, disableWhileTyping, leftHandedOn: int = -1
    accelProfile, clickMethod, scrollMethod: int = -1
    accelSpeed: Option[float]

  Device = ref object
    obj: RiverInputDeviceV1
    kind: int = -1
    name: string
    repeatSent: Option[tuple[rate, delay: int]]
    xkb: RiverXkbKeyboardV1
    keymapSet: bool
    layout: string
    numlock: int = -1
    li: RiverLibinputDeviceV1
    lp: Libinput

  KeymapState = enum
    ksNone, ksPending, ksSuccess, ksFailure

var
  settings: InputSettings
  manager: RiverInputManagerV1
  xkbConfig: RiverXkbConfigV1
  libinputConfig: RiverLibinputConfigV1
  devices: seq[Device]
  xkbContext: pointer
  keymap: RiverXkbKeymapV1
  keymapState: KeymapState
  keymapError: string

proc keymapWanted(): bool =
  let k = settings.keyboard
  k.layout.isSome or k.variant.isSome or k.options.isSome or k.model.isSome

# ---------------------------------------------------------------------------
# Applying the settings
# ---------------------------------------------------------------------------

proc applyRepeat(dev: Device) =
  let k = settings.keyboard
  if dev.kind != RIVER_INPUT_DEVICE_V1_TYPE_KEYBOARD.int or
      (k.repeatRate.isNone and k.repeatDelay.isNone):
    return
  let sent = (rate: k.repeatRate.get(DefaultRepeatRate), delay: k.repeatDelay.get(DefaultRepeatDelay))
  river_input_device_v1_set_repeat_info(dev.obj, sent.rate.int32, sent.delay.int32)
  dev.repeatSent = some(sent)

proc applyXkb(dev: Device, sendKeymap = true) =
  if dev.xkb.isNil:
    return
  if sendKeymap and keymapWanted():
    case keymapState
    of ksPending:
      return # Applied when the keymap is ready (a new keymap resets the numlock).
    of ksSuccess:
      river_xkb_keyboard_v1_set_keymap(dev.xkb, keymap)
      dev.keymapSet = true
    else:
      discard # Failed: River's keymap stays.
  if settings.keyboard.numlock.isSome:
    if settings.keyboard.numlock.get:
      river_xkb_keyboard_v1_numlock_enable(dev.xkb)
    else:
      river_xkb_keyboard_v1_numlock_disable(dev.xkb)

proc resultDone(data: pointer, self: RiverLibinputResultV1) {.cdecl.} =
  wl_proxy_destroy(self)

proc resultRejected(data: pointer, self: RiverLibinputResultV1) {.cdecl.} =
  log "libinput rejected an input setting", lvlWarn
  wl_proxy_destroy(self)

var resultListener = RiverLibinputResultV1Listener(
  success: resultDone, unsupported: resultRejected, invalid: resultRejected
)

proc track(result: RiverLibinputResultV1) =
  ## The result object is not destroyed by River's (destructor) event alone.
  discard river_libinput_result_v1_add_listener(result, addr resultListener, nil)

proc applyLibinput(dev: Device) =
  if dev.li.isNil or dev.kind != RIVER_INPUT_DEVICE_V1_TYPE_POINTER.int:
    return
  let
    li = dev.li
    p = dev.lp
    s = if p.tapFingers > 0: settings.touchpad else: settings.mouse
  if s.tap.isSome and p.tapFingers > 0:
    track river_libinput_device_v1_set_tap(li, s.tap.get.uint32)
  if s.naturalScroll.isSome and p.natural != 0:
    track river_libinput_device_v1_set_natural_scroll(li, s.naturalScroll.get.uint32)
  if s.disableWhileTyping.isSome and p.dwt != 0:
    track river_libinput_device_v1_set_dwt(li, s.disableWhileTyping.get.uint32)
  if s.leftHanded.isSome and p.leftHanded != 0:
    track river_libinput_device_v1_set_left_handed(li, s.leftHanded.get.uint32)
  if s.accelSpeed.isSome and p.profiles != 0:
    var speed = s.accelSpeed.get
    var array = WlArray(size: sizeof(speed).csize_t, alloc: sizeof(speed).csize_t, data: addr speed)
    track river_libinput_device_v1_set_accel_speed(li, addr array)
  if s.accelProfile.isSome:
    let profile =
      case s.accelProfile.get
      of apAdaptive: RIVER_LIBINPUT_DEVICE_V1_ACCEL_PROFILE_ADAPTIVE
      of apFlat: RIVER_LIBINPUT_DEVICE_V1_ACCEL_PROFILE_FLAT
    if (p.profiles and profile) != 0:
      track river_libinput_device_v1_set_accel_profile(li, profile)
  if s.clickMethod.isSome:
    let methodId =
      case s.clickMethod.get
      of cmClickfinger: RIVER_LIBINPUT_DEVICE_V1_CLICK_METHOD_CLICKFINGER
      of cmButtonAreas: RIVER_LIBINPUT_DEVICE_V1_CLICK_METHOD_BUTTON_AREAS
    if (p.clickMethods and methodId) != 0:
      track river_libinput_device_v1_set_click_method(li, methodId)
  if s.scrollMethod.isSome and p.scrollMethods != 0:
    let methodId =
      case s.scrollMethod.get
      of smTwoFinger: RIVER_LIBINPUT_DEVICE_V1_SCROLL_METHOD_TWO_FINGER
      of smEdge: RIVER_LIBINPUT_DEVICE_V1_SCROLL_METHOD_EDGE
      of smNone: RIVER_LIBINPUT_DEVICE_V1_SCROLL_METHOD_NO_SCROLL
    if methodId == 0 or (p.scrollMethods and methodId) != 0:
      track river_libinput_device_v1_set_scroll_method(li, methodId)

# ---------------------------------------------------------------------------
# Keymap
# ---------------------------------------------------------------------------

proc keymapSuccess(data: pointer, self: RiverXkbKeymapV1) {.cdecl.} =
  keymapState = ksSuccess
  for dev in devices:
    dev.applyXkb()

proc keymapFailure(data: pointer, self: RiverXkbKeymapV1, msg: cstring) {.cdecl.} =
  keymapState = ksFailure
  keymapError = $msg
  log "River could not create the keymap: " & keymapError & "; keeping its keymap", lvlError
  river_xkb_keymap_v1_destroy(self)
  keymap = nil

var keymapListener = RiverXkbKeymapV1Listener(success: keymapSuccess, failure: keymapFailure)

proc keymapFd(text: cstring): cint =
  ## A sealed memfd holding the keymap text; -1 on failure.
  result = memfd_create("nimdow-keymap", MfdCloexec or MfdAllowSealing)
  if result < 0:
    return
  var done = 0
  let size = text.len
  while done < size:
    let n = write(result, cast[pointer](cast[int](text) + done), size - done)
    if n <= 0:
      discard close(result)
      return -1
    done += n
  discard fcntl(result, FAddSeals, AllSeals)

proc newKeymap() =
  ## Compiles the keymap of the configured layout, variant, options and model
  ## and sends it to River; the keyboards get it when River reports success.
  if keymap != nil:
    river_xkb_keymap_v1_destroy(keymap)
    keymap = nil
  keymapState = ksNone
  keymapError = ""
  if xkbConfig.isNil or not keymapWanted():
    return
  let
    k = settings.keyboard
    model = k.model.get("")
    layout = k.layout.get("")
    variant = k.variant.get("")
    options = k.options.get("")
  var names = XkbRuleNames(
    model: model.cstring, layout: layout.cstring, variant: variant.cstring, options: options.cstring
  )
  if xkbContext.isNil:
    xkbContext = xkb_context_new(0)
  let compiled = xkb_keymap_new_from_names(xkbContext, addr names, 0)
  if compiled.isNil:
    keymapState = ksFailure
    keymapError = "xkbcommon cannot compile layout \"" & layout & "\", variant \"" & variant &
      "\", options \"" & options & "\", model \"" & model & "\""
    log keymapError & "; keeping River's keymap", lvlError
    return
  let text = xkb_keymap_get_as_string(compiled, RIVER_XKB_CONFIG_V1_KEYMAP_FORMAT_TEXT_V1.cint)
  xkb_keymap_unref(compiled)
  let fd = if text.isNil: -1.cint else: keymapFd(text)
  c_free(text)
  if fd < 0:
    keymapState = ksFailure
    keymapError = "cannot create the keymap file"
    log keymapError & "; keeping River's keymap", lvlError
    return
  keymap = river_xkb_config_v1_create_keymap(
    xkbConfig, fd, RIVER_XKB_CONFIG_V1_KEYMAP_FORMAT_TEXT_V1
  )
  discard close(fd) # libwayland sends its own copy
  keymapState = ksPending
  discard river_xkb_keymap_v1_add_listener(keymap, addr keymapListener, nil)

# ---------------------------------------------------------------------------
# Devices
# ---------------------------------------------------------------------------

proc deviceOf(device: RiverInputDeviceV1): Device =
  cast[Device](river_input_device_v1_get_user_data(device))

proc deviceRemoved(data: pointer, obj: RiverInputDeviceV1) {.cdecl.} =
  let dev = cast[Device](data)
  river_input_device_v1_destroy(obj)
  dev.obj = nil
  devices.delete devices.find(dev)
  GC_unref dev

proc deviceType(data: pointer, obj: RiverInputDeviceV1, kind: uint32) {.cdecl.} =
  cast[Device](data).kind = kind.int

proc deviceName(data: pointer, obj: RiverInputDeviceV1, name: cstring) {.cdecl.} =
  cast[Device](data).name = $name

proc deviceDone(data: pointer, obj: RiverInputDeviceV1) {.cdecl.} =
  cast[Device](data).applyRepeat()

var deviceListener = river_input_device_v1_noop_listener()
deviceListener.removed = deviceRemoved
deviceListener.`type` = deviceType
deviceListener.name = deviceName
deviceListener.done = deviceDone

proc managerDevice(data: pointer, obj: RiverInputManagerV1, id: RiverInputDeviceV1) {.cdecl.} =
  let dev = Device(obj: id)
  GC_ref dev
  devices.add dev
  discard river_input_device_v1_add_listener(id, addr deviceListener, cast[pointer](dev))

var managerListener = river_input_manager_v1_noop_listener()
managerListener.input_device = managerDevice

# The xkb keyboard and libinput device proxies carry their Device as user data
# once their `input_device` event has linked them.

proc xkbRemoved(data: pointer, obj: RiverXkbKeyboardV1) {.cdecl.} =
  let dev = cast[Device](river_xkb_keyboard_v1_get_user_data(obj))
  river_xkb_keyboard_v1_destroy(obj)
  if dev != nil:
    dev.xkb = nil
    GC_unref dev

proc xkbInputDevice(
  data: pointer, obj: RiverXkbKeyboardV1, device: RiverInputDeviceV1
) {.cdecl.} =
  let dev = deviceOf(device)
  if dev.isNil:
    return
  GC_ref dev
  dev.xkb = obj
  river_xkb_keyboard_v1_set_user_data(obj, cast[pointer](dev))

template xkbDev(obj: RiverXkbKeyboardV1): Device =
  cast[Device](river_xkb_keyboard_v1_get_user_data(obj))

proc xkbLayout(data: pointer, obj: RiverXkbKeyboardV1, index: uint32, name: cstring) {.cdecl.} =
  let dev = xkbDev(obj)
  if dev != nil:
    dev.layout = if name.isNil: "" else: $name

proc xkbNumlockOn(data: pointer, obj: RiverXkbKeyboardV1) {.cdecl.} =
  let dev = xkbDev(obj)
  if dev != nil: dev.numlock = 1

proc xkbNumlockOff(data: pointer, obj: RiverXkbKeyboardV1) {.cdecl.} =
  let dev = xkbDev(obj)
  if dev != nil: dev.numlock = 0

proc xkbDone(data: pointer, obj: RiverXkbKeyboardV1) {.cdecl.} =
  let dev = xkbDev(obj)
  if dev != nil: dev.applyXkb()

var xkbKeyboardListener = river_xkb_keyboard_v1_noop_listener()
xkbKeyboardListener.removed = xkbRemoved
xkbKeyboardListener.input_device = xkbInputDevice
xkbKeyboardListener.layout = xkbLayout
xkbKeyboardListener.numlock_enabled = xkbNumlockOn
xkbKeyboardListener.numlock_disabled = xkbNumlockOff
xkbKeyboardListener.done = xkbDone

proc xkbConfigKeyboard(data: pointer, obj: RiverXkbConfigV1, id: RiverXkbKeyboardV1) {.cdecl.} =
  discard river_xkb_keyboard_v1_add_listener(id, addr xkbKeyboardListener, nil)

var xkbConfigListener = river_xkb_config_v1_noop_listener()
xkbConfigListener.xkb_keyboard = xkbConfigKeyboard

proc liRemoved(data: pointer, obj: RiverLibinputDeviceV1) {.cdecl.} =
  let dev = cast[Device](river_libinput_device_v1_get_user_data(obj))
  river_libinput_device_v1_destroy(obj)
  if dev != nil:
    dev.li = nil
    GC_unref dev

proc liInputDevice(
  data: pointer, obj: RiverLibinputDeviceV1, device: RiverInputDeviceV1
) {.cdecl.} =
  let dev = deviceOf(device)
  if dev.isNil:
    return
  GC_ref dev
  dev.li = obj
  river_libinput_device_v1_set_user_data(obj, cast[pointer](dev))

proc liDone(data: pointer, obj: RiverLibinputDeviceV1) {.cdecl.} =
  let dev = cast[Device](river_libinput_device_v1_get_user_data(obj))
  if dev != nil: dev.applyLibinput()

template liEvent(name: untyped, T: typedesc, field: untyped) =
  ## Stores the value of a support/current event in the device's `lp.field`.
  proc name(data: pointer, obj: RiverLibinputDeviceV1, value: T) {.cdecl.} =
    let dev = cast[Device](river_libinput_device_v1_get_user_data(obj))
    if dev != nil:
      dev.lp.field = typeof(dev.lp.field)(value)

liEvent(liTapSupport, int32, tapFingers)
liEvent(liNaturalSupport, int32, natural)
liEvent(liLeftHandedSupport, int32, leftHanded)
liEvent(liDwtSupport, int32, dwt)
liEvent(liProfilesSupport, uint32, profiles)
liEvent(liClickSupport, uint32, clickMethods)
liEvent(liScrollSupport, uint32, scrollMethods)
liEvent(liTap, uint32, tap)
liEvent(liNatural, uint32, naturalScroll)
liEvent(liDwt, uint32, disableWhileTyping)
liEvent(liLeftHanded, uint32, leftHandedOn)
liEvent(liProfile, uint32, accelProfile)
liEvent(liClick, uint32, clickMethod)
liEvent(liScroll, uint32, scrollMethod)

proc liSpeed(data: pointer, obj: RiverLibinputDeviceV1, speed: ptr WlArray) {.cdecl.} =
  let dev = cast[Device](river_libinput_device_v1_get_user_data(obj))
  if dev != nil and speed.size >= sizeof(float).csize_t:
    dev.lp.accelSpeed = some(cast[ptr float](speed.data)[])

var liDeviceListener = river_libinput_device_v1_noop_listener()
liDeviceListener.removed = liRemoved
liDeviceListener.input_device = liInputDevice
liDeviceListener.done = liDone
liDeviceListener.tap_support = liTapSupport
liDeviceListener.natural_scroll_support = liNaturalSupport
liDeviceListener.left_handed_support = liLeftHandedSupport
liDeviceListener.dwt_support = liDwtSupport
liDeviceListener.accel_profiles_support = liProfilesSupport
liDeviceListener.click_method_support = liClickSupport
liDeviceListener.scroll_method_support = liScrollSupport
liDeviceListener.tap_current = liTap
liDeviceListener.natural_scroll_current = liNatural
liDeviceListener.dwt_current = liDwt
liDeviceListener.left_handed_current = liLeftHanded
liDeviceListener.accel_profile_current = liProfile
liDeviceListener.click_method_current = liClick
liDeviceListener.scroll_method_current = liScroll
liDeviceListener.accel_speed_current = liSpeed

proc libinputConfigDevice(
  data: pointer, obj: RiverLibinputConfigV1, id: RiverLibinputDeviceV1
) {.cdecl.} =
  discard river_libinput_device_v1_add_listener(id, addr liDeviceListener, nil)

var libinputConfigListener = river_libinput_config_v1_noop_listener()
libinputConfigListener.libinput_device = libinputConfigDevice

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

proc initInput*(registry: Registry, input: InputSettings) =
  ## Binds the input globals (a missing one is logged and its part skipped)
  ## and applies `input` to the devices as they are announced.
  settings = input
  let managerGlobal = registry.find("river_input_manager_v1")
  if managerGlobal.version < 2:
    log "river_input_manager_v1 (version 2) not available: the [input] settings are ignored", lvlWarn
    return
  manager = bindGlobal[RiverInputManagerV1](
    registry, managerGlobal, river_input_manager_v1_interface, 2
  )
  discard river_input_manager_v1_add_listener(manager, addr managerListener, nil)
  # The devices are announced by the manager first, so the linked globals can find them.
  let xkbGlobal = registry.find("river_xkb_config_v1")
  if xkbGlobal.version >= 2:
    xkbConfig = bindGlobal[RiverXkbConfigV1](
      registry, xkbGlobal, river_xkb_config_v1_interface, 2
    )
    discard river_xkb_config_v1_add_listener(xkbConfig, addr xkbConfigListener, nil)
  else:
    log "river_xkb_config_v1 (version 2) not available: no keymap and numlock settings", lvlWarn
  let libinputGlobal = registry.find("river_libinput_config_v1")
  if libinputGlobal.version >= 2:
    libinputConfig = bindGlobal[RiverLibinputConfigV1](
      registry, libinputGlobal, river_libinput_config_v1_interface, 2
    )
    discard river_libinput_config_v1_add_listener(
      libinputConfig, addr libinputConfigListener, nil
    )
  else:
    log "river_libinput_config_v1 (version 2) not available: no touchpad and mouse settings", lvlWarn
  newKeymap()

proc applyInput*(input: InputSettings) =
  ## Applies new settings (config reload) to the existing devices.
  if manager.isNil:
    return
  let
    old = settings.keyboard
    new = input.keyboard
    # Resending an unchanged keymap would reset the active layout, so only on change.
    keymapChanged = old.layout != new.layout or old.variant != new.variant or
      old.options != new.options or old.model != new.model
  settings = input
  if keymapChanged:
    newKeymap()
  for dev in devices:
    dev.applyRepeat()
    dev.applyXkb(sendKeymap = keymapChanged)
    dev.applyLibinput()

proc dumpJson*(): JsonNode =
  ## What was sent to River and what the devices report (`--dumpState`).
  proc known(value: int): JsonNode = (if value < 0: newJNull() else: %value)
  var list = newJArray()
  for dev in devices:
    var node = %*{
      "name": dev.name,
      "type": ["keyboard", "pointer", "touch", "tablet"][clamp(dev.kind, 0, 3)],
      "repeat": (if dev.repeatSent.isSome: %*{
        "rate": dev.repeatSent.get.rate, "delay": dev.repeatSent.get.delay} else: newJNull()),
      "xkb": (if dev.xkb.isNil: newJNull() else: %*{
        "keymapSet": dev.keymapSet, "layout": dev.layout, "numlock": known(dev.numlock)})
    }
    if dev.li != nil:
      let p = dev.lp
      node["libinput"] = %*{
        "kind": (if p.tapFingers > 0: "touchpad" else: "mouse"),
        "tapFingers": p.tapFingers, "tap": known(p.tap),
        "naturalScroll": known(p.naturalScroll), "disableWhileTyping": known(p.disableWhileTyping),
        "leftHanded": known(p.leftHandedOn), "accelProfile": known(p.accelProfile),
        "accelSpeed": (if p.accelSpeed.isSome: %p.accelSpeed.get else: newJNull()),
        "clickMethod": known(p.clickMethod), "scrollMethod": known(p.scrollMethod)
      }
    list.add node
  %*{
    "keymap": ["none", "pending", "success", "failure"][ord(keymapState)],
    "keymapError": keymapError,
    "devices": list
  }
