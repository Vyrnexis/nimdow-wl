# Installation

[Back to README](../README.md)

## Requirements

`river` 0.5 or newer. Runtime and build dependencies (libraries, `nim`, `pkgconf`, the `parsetoml` nimble package)
are listed in `packaging/arch/PKGBUILD`; `nimble install -d` fetches `parsetoml`.

## Arch Linux (AUR)

`packaging/arch/PKGBUILD` is a split package with two packages to choose from:

- `nimdow-wl-git`: the window manager only (River integration, systemd user target, portal config, man page).
- `nimdow-wl-desktop-git`: a complete desktop on a minimal install (dependencies are in the PKGBUILD). It adds:
  - `/etc/xdg/nimdow-wl/config.toml`: kitty, nimlaunch, volume/brightness/screenshot keys, status bar click
    actions, and autostart of swaybg, mako, a polkit agent, `nimdow-wl-status` and swayidle (locks with swaylock
    after 10 minutes and before suspend).
  - `/etc/xdg/nimdow-wl/status.toml`: the bar segments shown by `nimdow-wl-status`.

```sh
yay -S nimdow-wl-desktop-git      # or: cd packaging/arch && makepkg -si
sudo systemctl enable --now NetworkManager
river -c nimdow-wl                # from a TTY, or install a login manager (sddm, greetd-tuigreet)
```

On first run nimdow-wl copies `config.toml` and `nimdow-wl-status` copies `status.toml` to `~/.config/nimdow-wl/`
(existing files are kept). Edit those copies; see [Configuration](configuration.md).

## From source

```sh
nimble install -d     # dependencies
nimble release        # writes ./bin/nimdow-wl
```

Then install the files, as `packaging/arch/PKGBUILD` does:

| File | Destination |
| --- | --- |
| `bin/nimdow-wl` | `/usr/bin/nimdow-wl` |
| `config.default.toml` | `/usr/share/nimdow-wl/config.default.toml` |
| `wayland-sessions/nimdow-wl.desktop` | `/usr/share/wayland-sessions/nimdow-wl.desktop` |
| `systemd/nimdow-wl-session.target` | `/usr/lib/systemd/user/nimdow-wl-session.target` |
| `systemd/nimdow-wl-portals.conf` | `/usr/share/xdg-desktop-portal/nimdow-wl-portals.conf` |
| `doc/nimdow-wl.1` | `/usr/share/man/man1/nimdow-wl.1` |

## Starting a session

River is the compositor and nimdow-wl is its window manager. River needs a window manager to be useful, and
`river -c nimdow-wl` starts River with nimdow-wl as that client.

- Login manager: pick **nimdow-wl** (`nimdow-wl.desktop`, which runs `river -c nimdow-wl`). The separate **River**
  entry is River without a window manager and not what you want here.
- From a TTY: `river -c nimdow-wl`.

On startup nimdow-wl exports the display environment to D-Bus and the systemd user manager and starts
`nimdow-wl-session.target`. That target binds `graphical-session.target` and pulls in
`xdg-desktop-autostart.target`, so `~/.config/autostart` entries run. The target is stopped when nimdow-wl exits.

## Exiting

The `exitSession` control (default Ctrl+Alt+Delete) exits River and nimdow-wl. Killing nimdow-wl alone leaves River
running.
