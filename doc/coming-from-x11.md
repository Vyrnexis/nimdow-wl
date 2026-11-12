# Coming from X11 nimdow

[Back to README](../README.md)

nimdow-wl keeps nimdow's layout, controls and config format, but some things work differently on Wayland.

## Replaced features

- No `xsetroot`: the bar status is set with `nimdow-wl --status` (see [Status bar and tray](status-bar.md)).
- No XEmbed tray: use the StatusNotifierItem tray.
- Quitting is the `exitSession` control instead of a `pkill nimdow` key binding.
- Default programs are Wayland ones (`fuzzel`, `alacritty`) instead of `dmenu_run` and `st`.
- No urgency hints. The Java window-manager workarounds from the X11 README do not apply.

## App rules

App rules are evaluated when a window is first placed. A window without an `app_id` (or without a title, if a rule
matches on titles) is held back for one manage sequence; if the title arrives or changes within 500 ms, the rules are
evaluated again and apply tags and floating/fullscreen state, but never the monitor.

## Floating windows

- Floating windows (rules, scratchpad, dialogs) are placed and clamped inside the usable area: the output minus
  layer-shell exclusive zones and the bar. Auto-floated windows are centered at their own size.
- Toggling a tiled window to floating (Super+Space) centers it at `floatingWidth` x `floatingHeight` percent
  (default `50` x `50`, 10 to 100) of the usable area the first time, and restores its last floating geometry
  afterwards (Super+drag included). A new floating window larger than the usable area is shrunk to those
  percentages.
- Floating windows can be moved and resized from the keyboard. These do nothing on tiled windows:

  | Keys | Control |
  | --- | --- |
  | Super+Ctrl+H/J/K/L | `moveFloatingLeft/Down/Up/Right` |
  | Super+Ctrl+Shift+H/J/K/L | `resizeFloatingNarrower/Taller/Shorter/Wider` |
  | Super+C | `centerFloating` |

  `floatingStep` (default `40`) is the pixels per step; windows keep at least 50 px size and 50 px on screen.

## New settings

- `floatingWidth`, `floatingHeight`, `floatingStep` (see above).
- `barTagPadding`: space on each side of a tag label, default `8`.
- The tray and menu settings (see [Status bar and tray](status-bar.md#system-tray)).
- The `[input.*]` tables (see [Configuration](configuration.md#input-devices)).
