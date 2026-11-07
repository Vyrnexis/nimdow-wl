#!/usr/bin/env bash
# Dev script: build nimdow-wl and run it nested in River inside the current
# Wayland session (a window on your desktop).
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.nimble/bin:$PATH"

nimble debug

# Keep the nested instance away from the real systemd user session.
export NIMDOW_NO_SESSION=1
exec river -c "./bin/nimdow-wl --config ./config.default.toml"
