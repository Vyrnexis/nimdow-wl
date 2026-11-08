## Minimal bindings to librsvg, used to render SVG tray icons.

import ./cairo, ./pkgconfig

pkgConfig "librsvg-2.0"

type
  RsvgHandleObj = object
  RsvgHandle* = ptr RsvgHandleObj
  RsvgRectangle* {.bycopy.} = object
    x*, y*, width*, height*: cdouble

proc rsvg_handle_new_from_file*(filename: cstring, error: pointer): RsvgHandle
  {.importc, cdecl.}
proc rsvg_handle_render_document*(handle: RsvgHandle, cr: Cairo,
    viewport: ptr RsvgRectangle, error: pointer): cint {.importc, cdecl.}
