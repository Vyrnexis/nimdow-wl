# Package
version = "0.7.41"
author = "Vyrnexis, avahe-kellenberger (original nimdow)"
description = "A tiling window manager for the River Wayland compositor, written in Nim"
license = "GPL v2"
srcDir = "src"
binDir = "bin"
installExt = @["nim"]
bin = @["nimdow"]
namedBin["nimdow"] = "nimdow-wl"

# Deps
requires "nim >= 2.0.0"
requires "parsetoml"
requires "nimtest >= 0.1.0"

# Tasks
task debug, "Create a debug build":
  exec "nim -o:bin/nimdow-wl --deepcopy:on --linedir:on --debuginfo c src/nimdow.nim"

task release, "Build for release":
  exec "./build.sh"

task lint, "Lint all *.nim files":
  exec "nimpretty --indent:2 --maxLineLen:106 */**.nim"

task wlgen, "Regenerate Wayland protocol bindings from protocol/*.xml":
  exec "nim r --hints:off tools/wlgen.nim"

task e2e, "Run the end-to-end tests in a nested River (see tests/e2e/run.sh)":
  exec "bash tests/e2e/run.sh -b"
