# Configuration

[Back to README](../README.md)

`config.default.toml` documents every setting with comments, and `man nimdow-wl` lists them too. This page explains
where the config lives and the parts that need more than a one-line comment.

- [Config file](#config-file)
- [App rules](#app-rules)
- [Input devices](#input-devices)
- [Screen lock](#screen-lock)
- [Key bindings overlay](#key-bindings-overlay)
- [Other programs](#other-programs)

The status bar and system tray have their own page: [Status bar and tray](status-bar.md).

## Config file

nimdow-wl searches for a config file in this order:

1. `${XDG_CONFIG_HOME:-~/.config}/nimdow-wl/config.toml`
2. the first `nimdow-wl/config.toml` in `${XDG_CONFIG_DIRS:-/etc/xdg}` (installed by `nimdow-wl-desktop-git`)
3. the built-in copy of `config.default.toml`

If the user config does not exist at startup, the file chosen by 2 or 3 is copied to the user path (an existing
file is never overwritten) and loaded. If the copy fails (e.g. a read-only home) the source is used as is.
`/usr/share/nimdow-wl/config.default.toml` is a reference copy.

The default modifier is Super. Reload the config with Super+Shift+R. Use `nimdow-wl --config ./other.toml` to
start with another file.

## App rules

A `[[appRule]]` sets the tags, monitor and state of matching windows.

**Matching.** A rule applies to a window when its `class`, `instance` and `title` all match; the first matching
rule wins. `class` and `instance` are both compared with the window's `app_id`.

- Matching is exact and case-sensitive.
- A leading and/or trailing `*` matches a suffix, prefix or substring: `"*term"`, `"foot*"`, `"*foo*"`.
- An empty or missing field matches everything.

**Keys.**

| Key | Meaning |
| --- | --- |
| `monitor` | Output to open on (1 = first) |
| `tags` | Tags to put the window on |
| `state` | `normal`, `floating` or `fullscreen` |
| `x`, `y`, `width`, `height` | With `state = "floating"`: position and size in pixels. `x`/`y` are relative to the output's top-left corner and kept inside the usable area; without them the window is centered. |

Rules are evaluated when a window is first placed. A window without an `app_id` (or without a title, if a rule
matches on titles) is held back briefly; if the title arrives or changes within 500 ms, the rules are evaluated
again and apply tags and floating/fullscreen state, but never the monitor.

## Input devices

The optional `[input.keyboard]`, `[input.touchpad]` and `[input.mouse]` tables configure input devices through
River's `river_xkb_config_v1`, `river_libinput_config_v1` and `river_input_manager_v1` protocols. Every key is
optional: a key that is not set leaves River's or libinput's default alone, and invalid values are logged and
ignored.

| Table | Keys |
| --- | --- |
| `[input.keyboard]` | `layout`, `variant`, `options`, `model` (the xkb keymap), `repeatRate` (keys per second), `repeatDelay` (ms), `numlock` |
| `[input.touchpad]` | `tap`, `naturalScroll`, `disableWhileTyping`, `accelSpeed` (-1.0 to 1.0), `accelProfile` (`adaptive`, `flat`), `clickMethod` (`clickfinger`, `buttonareas`), `scrollMethod` (`twofinger`, `edge`, `none`) |
| `[input.mouse]` | `naturalScroll`, `accelSpeed`, `accelProfile`, `leftHanded` |

"Touchpad" means libinput devices with tap support; "mouse" means the other libinput pointers. The keymap is
compiled with xkbcommon and sent to every keyboard; if River rejects it, the log says so and River's keymap stays.

When settings apply:

- at startup, when a device appears, and on config reload (Super+Shift+R);
- only to devices that report support for the setting;
- removing a key from the config does not undo it until River restarts.

`nimdow-wl --dumpState` shows the keymap result and what each device reports. The desktop package enables
`[input.touchpad] tap = true`.

## Screen lock

The `lockSession` control (default Super+Escape) runs `lockCommand` from `[settings]` (default
`swaylock -f -c 282828`).

While River reports the session as locked (`ext-session-lock`), nimdow-wl disables all key and pointer bindings, so
window controls do nothing behind the lock screen. A `[[startProcess]]` entry with `whileLocked = true` stays active,
e.g. for the volume and brightness keys (the desktop package does this). `nimdow-wl --dumpState` shows `locked`.

The desktop package also autostarts swayidle: lock after 10 minutes, suspend after 15, lock before sleep.

## Key bindings overlay

Super+/ (the `toggleHotkeyOverlay` control) lists all key bindings of the loaded config, centred on the focused
output, in sections: Windows, Floating, Tags, Layout, Monitors, Scratchpad, Launch, Media & hardware, Session.

- Close it with Escape, a click on it or Super+/ again. Locking the session also closes it.
- A `[[startProcess]]` entry can have a `description = "Terminal"`, which the list shows instead of the command.
- With `hotkeyOverlayAtStartup = true` in `[settings]` the list opens when nimdow-wl starts. The desktop package
  sets it, so a new install shows its keys at first login.
- It uses the bar's fonts and colours (`barBackgroundColor`, `barForegroundColor`, `barSelectionColor`,
  `barHasWindowsColor`, `menuBorderColor`, `barTransparency`).

`nimdow-wl --dumpState` shows `overlayVisible`.

## Other programs

nimdow-wl works with any Wayland program. The defaults in `config.default.toml`, and suggestions:

- Launcher: Super+P runs `fuzzel`; any Wayland launcher (wofi, tofi, ...) works.
- Terminal: Super+Return starts `alacritty`.
- Notifications: [mako](https://github.com/emersion/mako) or any layer-shell notification daemon.
- Screenshots: [grim](https://sr.ht/~emersion/grim/) with [slurp](https://github.com/emersion/slurp), e.g.
  `grim -g "$(slurp)" - | wl-copy`.

Layer-shell programs (launchers, notification daemons, wallpapers, other bars) are supported, and their exclusive
zones shrink the tiled area.
