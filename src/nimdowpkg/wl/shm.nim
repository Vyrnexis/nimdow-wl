## Shared building blocks of the bar and the menu popups: a double-buffered
## wl_shm pool (`ShmPool`) and a wl_surface with fractional scale support
## (`ScaledSurface`: wp_viewporter + wp_fractional_scale_v1, falling back to
## the integer wl_surface.preferred_buffer_scale).

import std/[posix, monotimes, times]

import ../logger
import ./protocols/[wayland, viewporter, fractional_scale_v1]

proc memfd_create(name: cstring, flags: cuint): cint
  {.importc, header: "<sys/mman.h>".}

const
  MFD_CLOEXEC = 1.cuint
  ## After a failed allocation the same size is not retried for this long.
  retryBackoffMs = 2000'i64

type
  ShmBuf = ref object
    pool: ShmPool
    buffer: WlBuffer
    busy: bool

  ShmPool* = ref object
    shm: WlShm
    name: cstring
    ## Called when a buffer was released while `acquire` found none free
    ## (the owner then redraws).
    onRelease*: proc() {.closure.}
    mem: pointer
    memSize: int
    ## Buffer size in physical pixels.
    width*, height*: int
    buffers: array[2, ShmBuf]
    next: int
    pending: bool
    failedW, failedH: int
    failedAt: int64

proc nowMonoMs(): int64 = getMonoTime().ticks div 1_000_000

proc newShmPool*(shm: WlShm, name: cstring, onRelease: proc() {.closure.} = nil): ShmPool =
  ShmPool(shm: shm, name: name, onRelease: onRelease)

proc bufferRelease(data: pointer, obj: WlBuffer) {.cdecl.} =
  let buf = cast[ShmBuf](data)
  buf.busy = false
  let pool = buf.pool
  if pool.pending:
    pool.pending = false
    if pool.onRelease != nil:
      pool.onRelease()

var bufferListener = wl_buffer_noop_listener()
bufferListener.release = bufferRelease

proc free*(pool: ShmPool) =
  ## Destroys the buffers and unmaps the memory (a later `resize` allocates anew).
  for i in 0 .. pool.buffers.high:
    if pool.buffers[i] != nil:
      wl_buffer_destroy(pool.buffers[i].buffer)
      GC_unref pool.buffers[i]
      pool.buffers[i] = nil
  if pool.mem != nil:
    discard munmap(pool.mem, pool.memSize)
    pool.mem = nil
  pool.width = 0
  pool.height = 0
  pool.next = 0
  pool.pending = false

proc allocate(pool: ShmPool, width, height: int): bool =
  let
    stride = width * 4
    size = stride * height * 2
  if width <= 0 or height <= 0:
    return false
  let fd = memfd_create(pool.name, MFD_CLOEXEC)
  if fd < 0:
    log "memfd_create failed", lvlError
    return false
  if ftruncate(fd, size.Off) != 0:
    discard close(fd)
    log "ftruncate failed", lvlError
    return false
  let mem = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
  if mem == MAP_FAILED:
    discard close(fd)
    log "mmap failed", lvlError
    return false
  pool.mem = mem
  pool.memSize = size
  pool.width = width
  pool.height = height
  let wlPool = wl_shm_create_pool(pool.shm, fd, size.int32)
  for i in 0 .. pool.buffers.high:
    let buf = ShmBuf(pool: pool)
    GC_ref buf
    buf.buffer = wl_shm_pool_create_buffer(
      wlPool, (i * stride * height).int32, width.int32, height.int32, stride.int32,
      WL_SHM_FORMAT_ARGB8888
    )
    discard wl_buffer_add_listener(buf.buffer, addr bufferListener, cast[pointer](buf))
    pool.buffers[i] = buf
  wl_shm_pool_destroy(wlPool)
  discard close(fd)
  return true

proc resize*(pool: ShmPool, width, height: int): bool =
  ## Makes the buffers `width` x `height` physical pixels (a no-op when they
  ## already are). False when the memory could not be allocated; the same size
  ## is not retried (nor logged again) for a short while.
  if pool.mem != nil and pool.width == width and pool.height == height:
    return true
  if pool.failedW == width and pool.failedH == height and
      nowMonoMs() - pool.failedAt < retryBackoffMs:
    return false
  pool.free()
  if pool.allocate(width, height):
    pool.failedW = 0
    pool.failedH = 0
    return true
  # Nothing is left half allocated: `allocate` only commits on success.
  pool.failedW = width
  pool.failedH = height
  pool.failedAt = nowMonoMs()
  return false

proc acquire*(pool: ShmPool): int =
  ## Index of a buffer the compositor does not hold, or -1 when both are busy
  ## (`onRelease` is then called once one is released).
  for offset in 0 .. pool.buffers.high:
    let candidate = (pool.next + offset) mod pool.buffers.len
    if not pool.buffers[candidate].busy:
      pool.next = (candidate + 1) mod pool.buffers.len
      return candidate
  pool.pending = true
  return -1

proc data*(pool: ShmPool, index: int): pointer =
  ## The pixels (ARGB32, stride width * 4) of the acquired buffer.
  cast[pointer](cast[int](pool.mem) + index * pool.width * 4 * pool.height)

proc present*(pool: ShmPool, index: int, surface: WlSurface) =
  ## Attaches the buffer, damages it all and commits the surface.
  wl_surface_attach(surface, pool.buffers[index].buffer, 0, 0)
  wl_surface_damage_buffer(surface, 0, 0, pool.width.int32, pool.height.int32)
  wl_surface_commit(surface)
  pool.buffers[index].busy = true

proc destroy*(pool: ShmPool) =
  pool.free()

# ---------------------------------------------------------------------------
# Scaled surface
# ---------------------------------------------------------------------------

type
  ScaledSurface* = ref object
    surface*: WlSurface
    viewport: WpViewport
    fractional: WpFractionalScaleV1
    ## The scale the compositor prefers for this surface (x120), at least 120.
    scale120*: int
    ## Called when `scale120` changed.
    onScale*: proc() {.closure.}

proc scaleChanged(s: ScaledSurface, scale120: int) =
  let scale = max(120, scale120)
  if scale != s.scale120:
    s.scale120 = scale
    if s.onScale != nil:
      s.onScale()

proc fractionalPreferredScale(data: pointer, obj: WpFractionalScaleV1,
    scale: uint32) {.cdecl.} =
  cast[ScaledSurface](data).scaleChanged(scale.int)

var fractionalListener = wp_fractional_scale_v1_noop_listener()
fractionalListener.preferred_scale = fractionalPreferredScale

proc surfacePreferredBufferScale(data: pointer, obj: WlSurface,
    factor: int32) {.cdecl.} =
  ## Integer scale; only used when fractional scale is unavailable.
  let s = cast[ScaledSurface](data)
  if s.fractional == nil:
    s.scaleChanged(factor.int * 120)

var surfaceListener = wl_surface_noop_listener()
surfaceListener.preferred_buffer_scale = surfacePreferredBufferScale

proc newScaledSurface*(compositor: WlCompositor, viewporter: WpViewporter,
    fractionalManager: WpFractionalScaleManagerV1, initialScale120: int,
    onScale: proc() {.closure.} = nil): ScaledSurface =
  result = ScaledSurface(
    surface: wl_compositor_create_surface(compositor),
    scale120: max(120, initialScale120), onScale: onScale
  )
  GC_ref result
  discard wl_surface_add_listener(result.surface, addr surfaceListener, cast[pointer](result))
  if fractionalManager != nil:
    result.viewport = wp_viewporter_get_viewport(viewporter, result.surface)
    result.fractional = wp_fractional_scale_manager_v1_get_fractional_scale(
      fractionalManager, result.surface
    )
    discard wp_fractional_scale_v1_add_listener(
      result.fractional, addr fractionalListener, cast[pointer](result)
    )

proc physical*(s: ScaledSurface, logical: int): int =
  ## A logical length in physical pixels.
  (logical * s.scale120 + 60) div 120

proc prepare*(s: ScaledSurface, width, height: int) =
  ## Before attaching a physical size buffer that shows `width` x `height`
  ## logical pixels.
  if s.viewport != nil:
    wl_surface_set_buffer_scale(s.surface, 1)
    wp_viewport_set_destination(s.viewport, width.int32, height.int32)
  else:
    wl_surface_set_buffer_scale(s.surface, (s.scale120 div 120).int32)

proc destroy*(s: ScaledSurface) =
  ## Destroys the surface and its helper objects; the surface must have no
  ## role objects left.
  if s.fractional != nil:
    wp_fractional_scale_v1_destroy(s.fractional)
    wp_viewport_destroy(s.viewport)
  wl_surface_destroy(s.surface)
  GC_unref s
