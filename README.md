# nimdow-wl

nimdow-wl is a tiling window manager for Wayland. It runs as a window-manager client of the
[River](https://codeberg.org/river/river) compositor (0.5 or newer) through the `river-window-management-v1`
protocol: River handles rendering and input, nimdow-wl decides where windows go. It installs side by side with the X11 `nimdow`
package because every installed name differs (binary, config directory, session, man page, ...).

This is a Wayland port of [nimdow](https://github.com/avahe-kellenberger/nimdow) by avahe-kellenberger,
written in [Nim](https://nim-lang.org/). X11 is no longer supported. Licensed under the GPL-2.0 (see `LICENSE`).

## Features

- dwm-style tiling: master/stack layout with adjustable master count and width, tags (workspaces), floating and
  fullscreen windows, a scratchpad, multiple monitors, and app rules (tags, monitor, floating/fullscreen state).
- Built-in status bar: tags on the left, the focused window's title in the center, status text on the right.
  Set the text with `nimdow-wl --status "text"`.
- System tray using the StatusNotifierItem protocol, with dbusmenu context menus and tooltips.
- Layer-shell support: launchers, notification daemons, wallpapers and other bars work, and their exclusive zones
  shrink the tiled area. The bar is rendered at the output's (fractional) scale.
- systemd user session integration: on startup nimdow-wl exports the display environment to D-Bus and the systemd
  user manager and starts `nimdow-wl-session.target`, which binds `graphical-session.target` and pulls in
  `xdg-desktop-autostart.target`, so `~/.config/autostart` entries run. The target is stopped when nimdow-wl exits.
- Keyboard and touchpad settings (`[input]`): xkb layout/variant/options/model, key repeat, numlock, and libinput
  options (tap, natural scroll, acceleration, ...) for touchpads and mice.
- TOML configuration with a reload key binding, plus a command line client for the window manager controls.

## Requirements

- `river` >= 0.5
- Runtime libraries: `wayland`, `libxkbcommon`, `cairo`, `pango`, `librsvg`, `systemd-libs`, `glib2`,
  `harfbuzz`, `gdk-pixbuf2`
- Build: `nim`, `pkgconf`, `git`, and the `parsetoml` nimble package (`nimble` fetches it)
- Optional: `xdg-desktop-portal-gtk` (portals), `mako` (notifications)

## Installation

### Arch Linux

See [Install (Arch / AUR)](#install-arch--aur) below. `nimdow-wl-git` can be installed alongside the X11 `nimdow`.

### Install (Arch / AUR)

`packaging/arch/PKGBUILD` is a split package:

- `nimdow-wl-git`: the window manager only (River integration, systemd user target, portal config, man page).
- `nimdow-wl-desktop-git`: a complete desktop on a minimal install. It pulls in `nimdow-wl-git` and ships
  `/etc/xdg/nimdow-wl/config.toml` (kitty, nimlaunch, firefox on super+i, volume/brightness/screenshot keys, status bar
  click actions, autostarted swaybg (with the "Reverie" wallpaper, `/usr/share/backgrounds/nimdow-wl/reverie.jpg`), mako, polkit agent, `nimdow-wl-status` and swayidle, which locks with swaylock after 10 minutes and before suspend) and
  `/etc/xdg/nimdow-wl/status.toml` (the status bar segments).

```sh
yay -S nimdow-wl-desktop-git      # or: cd packaging/arch && makepkg -si
sudo systemctl enable --now NetworkManager
river -c nimdow-wl                # from a TTY, or install a login manager (sddm, greetd-tuigreet)
```

On first login the desktop configs are copied to `~/.config/nimdow-wl/config.toml` and
`~/.config/nimdow-wl/status.toml`; edit those copies.
`nimdow-wl-desktop-git` depends on: `nimdow-wl-git polkit-gnome mako swaybg swaylock swayidle xdg-desktop-portal-gtk xorg-xwayland
gnome-keyring kitty nimlaunch-bin nimdow-wl-status wl-clipboard grim slurp libnotify pipewire pipewire-pulse
wireplumber brightnessctl networkmanager ttf-meslo-nerd pacman-contrib`. Optional: `pavucontrol`, `nautilus`,
`adw-gtk-theme`, `network-manager-applet`, `sddm`, `greetd-tuigreet`.

### From source

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

## Running

River is the compositor and nimdow-wl is its window manager; River needs a window manager to be useful, and
`river -c nimdow-wl` starts River with nimdow-wl as that client.

- Login manager: pick **nimdow-wl** (`nimdow-wl.desktop`, which runs `river -c nimdow-wl`). The separate **River** entry
  is River without a window manager and not what you want here.
- From a TTY: `river -c nimdow-wl`.

Exiting: the `exitSession` control (default Ctrl+Alt+Delete) exits River and nimdow-wl. Killing nimdow-wl alone leaves
River running.

## Configuration

nimdow-wl searches for a config file in this order:

1. `${XDG_CONFIG_HOME:-~/.config}/nimdow-wl/config.toml`
2. the first `nimdow-wl/config.toml` in `${XDG_CONFIG_DIRS:-/etc/xdg}` (installed by `nimdow-wl-desktop-git`)
3. the built-in copy of `config.default.toml`

If the user config does not exist at startup, the file chosen by 2 or 3 is copied to the user path (an existing file
is never overwritten) and loaded. If the copy fails (e.g. a read-only home) the source is used as is.
`/usr/share/nimdow-wl/config.default.toml` is a reference copy.

`config.default.toml` documents every setting. The default modifier is Super; reload the config with
Super+Shift+R. The [upstream wiki](https://github.com/avahe-kellenberger/nimdow/wiki/User-Configuration-File)
describes the config format in more detail (the X11-specific parts do not apply). Use
`nimdow-wl --config ./other.toml` to start with another file.

### Input devices

The optional `[input.keyboard]`, `[input.touchpad]` and `[input.mouse]` tables configure the input devices
through River's `river_xkb_config_v1`, `river_libinput_config_v1` and `river_input_manager_v1` protocols. Every
key is optional; a key that is not set leaves River's or libinput's default alone, and invalid values are logged and
ignored.

- Keyboard: `layout`, `variant`, `options`, `model` (the xkb keymap, compiled with xkbcommon and sent to every
  keyboard; if River rejects it, the log says so and River's keymap stays), `repeatRate` (keys per second),
  `repeatDelay` (ms) and `numlock`.
- Touchpad (libinput devices with tap support): `tap`, `naturalScroll`, `disableWhileTyping`, `accelSpeed`
  (-1.0 to 1.0), `accelProfile` (`adaptive`, `flat`), `clickMethod` (`clickfinger`, `buttonareas`) and `scrollMethod`
  (`twofinger`, `edge`, `none`).
- Mouse (the other libinput pointers): `naturalScroll`, `accelSpeed`, `accelProfile`, `leftHanded`.

The settings are applied at startup, when a device appears and on config reload (Super+Shift+R). A setting is only
sent to a device that reports support for it. Removing a key from the config does not undo it until River restarts.
`nimdow-wl --dumpState` shows the keymap result and what each device reports. The desktop package enables
`[input.touchpad] tap = true`.

### Screen lock

The `lockSession` control (default Super+Escape) runs `lockCommand` (`[settings]`, default
`swaylock -f -c 282828`). While River reports the session as locked (`ext-session-lock`), nimdow-wl disables all key
and pointer bindings, so window controls do nothing behind the lock screen. A `[[startProcess]]` entry with
`whileLocked = true` stays active, e.g. for the volume and brightness keys (the desktop package does this).
`nimdow-wl --dumpState` shows `locked`. The desktop package also autostarts swayidle (lock after 10 minutes, suspend
after 15, lock before sleep).

### Key bindings overlay

Super+/ (the `toggleHotkeyOverlay` control) lists all key bindings of the loaded config in sections (Windows, Floating,
Tags, Layout, Monitors, Scratchpad, Launch, Media & hardware, Session), centred on the focused output. Escape, a click
on it or Super+/ again closes it, as does locking the session. A `[[startProcess]]` entry can have a
`description = "Terminal"`, which is what the list shows instead of the command. With
`hotkeyOverlayAtStartup = true` in `[settings]` the list opens when nimdow-wl starts (the desktop package sets it, so a
new install shows its keys at first login). It uses the bar's fonts and colours (`barBackgroundColor`,
`barForegroundColor`, `barSelectionColor`, `barHasWindowsColor`, `menuBorderColor`, `barTransparency`).
`nimdow-wl --dumpState` shows `overlayVisible`.

### Status bar text

nimdow-wl has no built-in clock or system info; a script sets the text:

```sh
while true; do nimdow-wl --status "$(date +%H:%M)"; sleep 30; done
```

Put that loop in `[autostart] exec` in the config (or in a script you start from there).

### Other programs

- Launcher: the default config binds Super+P to `fuzzel`; any Wayland launcher (wofi, tofi, ...) works.
- Terminal: Super+Return starts `alacritty`; change it in the config.
- Notifications: use [mako](https://github.com/emersion/mako) (or any layer-shell notification daemon).
- Screenshots: [grim](https://sr.ht/~emersion/grim/) with [slurp](https://github.com/emersion/slurp), e.g.
  `grim -g "$(slurp)" - | wl-copy`.

## System tray

Tray icons are shown on the right of the bar and use the StatusNotifierItem D-Bus protocol (XEmbed does not
exist on Wayland). It needs the D-Bus session bus.

- nimdow-wl tries to own `org.kde.StatusNotifierWatcher`. If another program already owns it (waybar, noctalia, ...),
  nimdow-wl acts as a host only and takes over the name if the other watcher goes away.
- Left click calls `Activate` (or opens the menu for menu-only items), middle click `SecondaryActivate`,
  right click opens the item's context menu, scrolling sends `Scroll`. Items with status `Passive` are hidden.
- Icons come from the item's `IconThemePath`, the icon theme (`trayIconTheme`, else `gtk-icon-theme-name` from
  the GTK 3/4 `settings.ini`, else Adwaita) and its `Inherits` chain, hicolor and `/usr/share/pixmaps`; otherwise
  the item's pixmap, otherwise a placeholder letter.
- Menus (`com.canonical.dbusmenu`) support submenus, check/radio marks, icons and keyboard navigation (Up/Down,
  Right/Enter/Space, Left, Escape). Hovering an icon shows its tooltip.
- Settings in `[settings]`: `trayEnabled`, `trayMonitor` (`1` = first monitor, `0` = follow the selected one),
  `trayIconPadding`, `trayIconSpacing`, `trayIconTheme`, `menuBorderColor`, `menuWidthMin`.

## Differences from X11 nimdow

- No `xsetroot`: the bar status is set with `nimdow-wl --status`. There is no XEmbed tray; use the SNI tray above.
- App rules match the window's `app_id`: both `class` and `instance` are compared against it.
- Quitting is the `exitSession` control instead of a `pkill nimdow` key binding.
- Default programs are Wayland ones (`fuzzel`, `alacritty`) instead of `dmenu_run` and `st`.
- App rules are evaluated when a window is first placed. A window without an `app_id` (or without a title, if a
  rule matches on titles) is held back for one manage sequence; if the title arrives or changes within 500 ms,
  the rules are evaluated again and apply tags and floating/fullscreen state, but never the monitor.
- Floating windows (rules, scratchpad, dialogs) are placed and clamped inside the usable area (the output minus
  layer-shell exclusive zones and the bar). Auto-floated windows are centered at their own size.
- Toggling a tiled window to floating (super+space) centers it at `floatingWidth` x `floatingHeight` percent
  (default `50` x `50`, 10 to 100) of the usable area the first time, and restores its last floating geometry
  afterwards (super+drag included). A new floating window larger than the usable area is shrunk to those percentages.
- Floating windows can be moved with super+ctrl+h/j/k/l (`moveFloatingLeft/Down/Up/Right`), resized with
  super+ctrl+shift+h/j/k/l (`resizeFloatingNarrower/Taller/Shorter/Wider`) and centered with super+c
  (`centerFloating`). They do nothing on tiled windows. `floatingStep` (default `40`) is the pixels per step; windows
  keep at least 50 px size and 50 px on screen.
- New settings: `floatingWidth`, `floatingHeight`, `floatingStep`, `barTagPadding` (space on each side of a tag label, default `8`), the tray and menu settings.
- No urgency hints. The Java window-manager workarounds from the X11 README do not apply.

## Command line

```
nimdow-wl                      start nimdow-wl (as the River window manager client)
nimdow-wl -c, --config <file>  use another config file
nimdow-wl -v, --version        print version information
nimdow-wl --status "text"      set the status text of the running instance
nimdow-wl --dumpState [file]   write the running instance's state as JSON
                               (default $XDG_RUNTIME_DIR/nimdow-wl-state.json)
```

Window manager controls can also be run through the same client, e.g. `nimdow-wl togglefloating` or
`nimdow-wl gototag 3`. See `man nimdow-wl` and the
[upstream wiki](https://github.com/avahe-kellenberger/nimdow/wiki/CLI-Client) for the command list.

## Development

Nimble tasks:

- `nimble debug`: debug build to `bin/nimdow-wl`
- `nimble release`: release build
- `nimble test`: run the unit tests (needs `nimtest`)
- `nimble wlgen`: regenerate the Wayland protocol bindings from `protocol/*.xml`
- `nimble e2e`: build and run the end-to-end tests
- `nimble nested`: build a debug binary and run it in a River window nested in your current Wayland session
- `nimble lint`: run `nimpretty`

`bash tools/dev-nested.sh` (or `nimble nested`) builds a debug binary and runs it in a River window nested in your
current Wayland session, using `config.default.toml`.

`bash tests/e2e/run.sh [-o outdir] [-b] [-s scenario,...]` runs nimdow-wl in a nested River with
`tests/e2e/config.toml`. It needs `river`, `grim`, `alacritty`, `jq`, `dbus-run-session`, python3 with PyGObject
and a running Wayland session. Input is injected through the virtual keyboard and pointer protocols by
`bin/nimdowinput` (built by `-b` or on first use), results are asserted through `nimdow-wl --dumpState`, and the
nested River runs in a private D-Bus session with `tests/e2e/fake_sni.py` as fake tray items. Screenshots, logs
and `results.txt` go to the output directory (default `./e2e-out`).

`sudo tools/fresh-install-test.sh [--keep]` tests the AUR packages on a clean system: it pacstraps a minimal Arch
into a throwaway systemd-nspawn container, installs `nimdow-wl-desktop-git` with paru as a new user, boots the
container and runs the desktop headless, checking the first-run config, autostart, session targets, portal and
logout. Results go to `/var/tmp/nimdow-wl-test-result`. It needs about 2 GB of disk and network access.

Set `NIMDOW_NO_SESSION=1` to skip the systemd/D-Bus session setup (the nested runs above do this, so they do not
touch your real user session).

## Known limitations

- Some clients ignore the size they are offered when they open floating. Alacritty (winit) is one: a floating
  rule's `width`/`height` is sent, but it opens at its own default size.
- `maximize_requested` is ignored.
- River sends no event for clicks that hit neither a window nor one of nimdow-wl's surfaces (the bare desktop), so
  an open tray menu is not dismissed by such a click; use Escape, a window, the bar or a tag change.
- Tray menus taller than the screen are not scrollable.
