# nimdow-wayland

nimdow-wayland is a tiling window manager for Wayland. It runs as a window-manager client of the
[River](https://codeberg.org/river/river) compositor (0.5 or newer) through the `river-window-management-v1`
protocol: River handles rendering and input, nimdow decides where windows go. The binary, the config directory
(`~/.config/nimdow/`) and the session name all remain `nimdow`.

This is a Wayland port of [nimdow](https://github.com/avahe-kellenberger/nimdow) by avahe-kellenberger,
written in [Nim](https://nim-lang.org/). X11 is no longer supported. Licensed under the GPL-2.0 (see `LICENSE`).

## Features

- dwm-style tiling: master/stack layout with adjustable master count and width, tags (workspaces), floating and
  fullscreen windows, a scratchpad, multiple monitors, and app rules (tags, monitor, floating/fullscreen state).
- Built-in status bar: tags on the left, the focused window's title in the center, status text on the right.
  Set the text with `nimdow --status "text"`.
- System tray using the StatusNotifierItem protocol, with dbusmenu context menus and tooltips.
- Layer-shell support: launchers, notification daemons, wallpapers and other bars work, and their exclusive zones
  shrink the tiled area. The bar is rendered at the output's (fractional) scale.
- systemd user session integration: on startup nimdow exports the display environment to D-Bus and the systemd
  user manager and starts `nimdow-session.target`, which binds `graphical-session.target` and pulls in
  `xdg-desktop-autostart.target`, so `~/.config/autostart` entries run. The target is stopped when nimdow exits.
- TOML configuration with a reload key binding, plus a command line client for the window manager controls.

## Requirements

- `river` >= 0.5
- Runtime libraries: `wayland`, `libxkbcommon`, `cairo`, `pango`, `librsvg`, `systemd-libs`, `glib2`,
  `harfbuzz`, `gdk-pixbuf2`
- Build: `nim`, `pkgconf`, `git`, and the `parsetoml` nimble package (`nimble` fetches it)
- Optional: `xdg-desktop-portal-gtk` (portals), `mako` (notifications)

## Installation

### Arch Linux

```sh
cd packaging/arch
makepkg -si
```

This builds and installs `nimdow-wayland-git` (it conflicts with `nimdow`, `nimdow-bin` and `nimdow-git`).
The default config ends up in `/usr/share/nimdow/config.default.toml`.

### From source

```sh
nimble install -d     # dependencies
nimble release        # runs ./build.sh, writes ./bin/nimdow
```

Then install the files, as `packaging/arch/PKGBUILD` does:

| File | Destination |
| --- | --- |
| `bin/nimdow` | `/usr/bin/nimdow` |
| `config.default.toml` | `/usr/share/nimdow/config.default.toml` |
| `wayland-sessions/nimdow.desktop` | `/usr/share/wayland-sessions/nimdow.desktop` |
| `systemd/nimdow-session.target` | `/usr/lib/systemd/user/nimdow-session.target` |
| `systemd/nimdow-portals.conf` | `/usr/share/xdg-desktop-portal/nimdow-portals.conf` |
| `doc/nimdow.1` | `/usr/share/man/man1/nimdow.1` |

## Running

River is the compositor and nimdow is its window manager; River needs a window manager to be useful, and
`river -c nimdow` starts River with nimdow as that client.

- Login manager: pick **nimdow** (`nimdow.desktop`, which runs `river -c nimdow`). The separate **River** entry
  is River without a window manager and not what you want here.
- From a TTY: `river -c nimdow`.

Exiting: the `exitSession` control (default Ctrl+Alt+Delete) exits River and nimdow. Killing nimdow alone leaves
River running.

## Configuration

nimdow searches for a config file in this order:

1. `${XDG_CONFIG_HOME}/nimdow/config.toml`
2. `${HOME}/.config/nimdow/config.toml`
3. `/usr/share/nimdow/config.default.toml`

If none is found, nimdow does not start. Start from the default:

```sh
mkdir -p ~/.config/nimdow
cp /usr/share/nimdow/config.default.toml ~/.config/nimdow/config.toml
```

`config.default.toml` documents every setting. The default modifier is Super; reload the config with
Super+Shift+R. The [upstream wiki](https://github.com/avahe-kellenberger/nimdow/wiki/User-Configuration-File)
describes the config format in more detail (the X11-specific parts do not apply). Use
`nimdow --config ./other.toml` to start with another file.

### Status bar text

nimdow has no built-in clock or system info; a script sets the text:

```sh
while true; do nimdow --status "$(date +%H:%M)"; sleep 30; done
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

- nimdow tries to own `org.kde.StatusNotifierWatcher`. If another program already owns it (waybar, noctalia, ...),
  nimdow acts as a host only and takes over the name if the other watcher goes away.
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

- No `xsetroot`: the bar status is set with `nimdow --status`. There is no XEmbed tray; use the SNI tray above.
- App rules match the window's `app_id`: both `class` and `instance` are compared against it.
- Quitting is the `exitSession` control instead of a `pkill nimdow` key binding.
- Default programs are Wayland ones (`fuzzel`, `alacritty`) instead of `dmenu_run` and `st`.
- App rules are evaluated when a window is first placed. A window without an `app_id` (or without a title, if a
  rule matches on titles) is held back for one manage sequence; if the title arrives or changes within 500 ms,
  the rules are evaluated again and apply tags and floating/fullscreen state, but never the monitor.
- Floating windows (rules, scratchpad, dialogs) are placed and clamped inside the usable area (the output minus
  layer-shell exclusive zones and the bar). Auto-floated windows are centered at their own size.
- New settings: `barTagPadding` (space on each side of a tag label, default `8`), the tray and menu settings.
- No urgency hints. The Java window-manager workarounds from the X11 README do not apply.

## Command line

```
nimdow                         start nimdow (as the River window manager client)
nimdow -c, --config <file>     use another config file
nimdow -v, --version           print version information
nimdow --status "text"         set the status text of the running instance
nimdow --dumpState [file]      write the running instance's state as JSON
                               (default $XDG_RUNTIME_DIR/nimdow-state.json)
```

Window manager controls can also be run through the same client, e.g. `nimdow togglefloating` or
`nimdow gototag 3`. See `man nimdow` and the
[upstream wiki](https://github.com/avahe-kellenberger/nimdow/wiki/CLI-Client) for the command list.

## Development

Nimble tasks:

- `nimble debug`: debug build to `bin/nimdow`
- `nimble release`: release build (`build.sh`)
- `nimble wlgen`: regenerate the Wayland protocol bindings from `protocol/*.xml`
- `nimble e2e`: build and run the end-to-end tests
- `nimble lint`: run `nimpretty`

`./run.sh` builds a debug binary and runs it in a River window nested in your current Wayland session, using
`config.default.toml`.

`bash tests/e2e/run.sh [-o outdir] [-b] [-s scenario,...]` runs nimdow in a nested River with
`tests/e2e/config.toml`. It needs `river`, `grim`, `alacritty`, `jq`, `dbus-run-session`, python3 with PyGObject
and a running Wayland session. Input is injected through the virtual keyboard and pointer protocols by
`bin/nimdowinput` (built by `-b` or on first use), results are asserted through `nimdow --dumpState`, and the
nested River runs in a private D-Bus session with `tests/e2e/fake_sni.py` as fake tray items. Screenshots, logs
and `results.txt` go to the output directory (default `./e2e-out`).

Set `NIMDOW_NO_SESSION=1` to skip the systemd/D-Bus session setup (the nested runs above do this, so they do not
touch your real user session).

## Known limitations

- Some clients ignore the size they are offered when they open floating. Alacritty (winit) is one: a floating
  rule's `width`/`height` is sent, but it opens at its own default size.
- `maximize_requested` is ignored.
- River sends no event for clicks that hit neither a window nor one of nimdow's surfaces (the bare desktop), so
  an open tray menu is not dismissed by such a click; use Escape, a window, the bar or a tag change.
- Tray menus taller than the screen are not scrollable.
