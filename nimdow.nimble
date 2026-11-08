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
requires "parsetoml >= 0.7.2"
taskRequires "test", "nimtest >= 0.1.0"

# Tasks
task debug, "Create a debug build":
  exec "nim -o:bin/nimdow-wl --linedir:on --debuginfo c src/nimdow.nim"

task release, "Build for release":
  # The commit (shown by --version): LATEST_COMMIT if set, else from git.
  if getEnv("LATEST_COMMIT").len == 0:
    let (hash, code) = gorgeEx("git rev-parse --short HEAD")
    if code == 0 and hash.strip().len > 0:
      var commit = hash.strip()
      if gorgeEx("git diff-index --quiet HEAD").exitCode != 0:
        commit &= "*"
      putEnv("LATEST_COMMIT", commit)
    else:
      echo "Not in a git checkout: building without a commit id"
  echo "--- Building with latest commit: ", getEnv("LATEST_COMMIT"), " ---"
  exec "nim c -o:bin/nimdow-wl -d:release src/nimdow.nim"

task test, "Run the unit tests (nimtest)":
  exec "nimtest"

task lint, "Lint all *.nim files (not the generated protocol bindings)":
  exec "find src tests tools -name '*.nim' -not -path '*/protocols/*' -print0 | " &
    "xargs -0 -n1 nimpretty --indent:2 --maxLineLen:106"

task wlgen, "Regenerate Wayland protocol bindings from protocol/*.xml":
  exec "nim r --hints:off tools/wlgen.nim"

task e2e, "Run the end-to-end tests in a nested River (see tests/e2e/run.sh)":
  exec "bash tests/e2e/run.sh -b"

task nested, "Build a debug binary and run it in a River window nested in the current session":
  exec "bash tools/dev-nested.sh"
