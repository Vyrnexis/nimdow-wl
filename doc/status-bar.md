# Status bar and tray

[Back to README](../README.md)

The bar shows the tags on the left, the focused window's title in the center and the status text and tray icons on
the right. It is rendered at the output's (fractional) scale.

## Status text

nimdow-wl has no built-in clock or system info; a script sets the text with `nimdow-wl --status`:

```sh
while true; do nimdow-wl --status "$(date +%H:%M)"; sleep 30; done
```

Put that loop in `[autostart] exec` in the config. The desktop package already feeds the bar through
`nimdow-wl-status`, configured in `~/.config/nimdow-wl/status.toml`.

### Colours and fonts

The text may contain ANSI SGR sequences (`ESC[...m`):

| Code | Effect |
| --- | --- |
| `0` | reset |
| `30-37`, `90-97` | foreground colour |
| `40-47`, `100-107` | background colour |
| `39`, `49` | default foreground / background |
| `38;5;N`, `48;5;N` | 256-colour foreground / background |
| `38;2;R;G;B`, `48;2;R;G;B` | 24-bit foreground / background |
| `11-20` | use the 1st to 10th font of `barFonts` |

### Segments

The byte `0x1F` splits the text into segments, e.g. `nimdow-wl --status "$(printf 'one\037two')"`. Each segment is a
separate click region (see below).

## Click regions

A `[[startProcess]]` with `clickRegion = N` (and no `keys`) runs its command when region N is clicked:

- region 0 is the window title;
- regions 1, 2, ... are the status segments, left to right;
- tags are not regions.

The command can use these placeholders:

| Placeholder | Value |
| --- | --- |
| `%0` | all of the below |
| `%1` | index of the clicked character |
| `%2`, `%3` | the region's x and y |
| `%4`, `%5` | the click's x and y |
| `%6` | the region's width |
| `%7` | the button: 1 left, 2 middle, 3 right, 4 scroll up, 5 scroll down |

## System tray

Tray icons are shown on the right of the bar and use the StatusNotifierItem D-Bus protocol (XEmbed does not exist on
Wayland). It needs the D-Bus session bus.

nimdow-wl tries to own `org.kde.StatusNotifierWatcher`. If another program already owns it (waybar, noctalia, ...),
nimdow-wl acts as a host only and takes over the name if the other watcher goes away.

**Mouse actions.**

- Left click calls `Activate` (or opens the menu for menu-only items).
- Middle click calls `SecondaryActivate`.
- Right click opens the item's context menu.
- Scrolling sends `Scroll`.
- Hovering an icon shows its tooltip.

Items with status `Passive` are hidden.

**Menus** (`com.canonical.dbusmenu`) support submenus, check/radio marks, icons and keyboard navigation: Up/Down,
Right/Enter/Space to open, Left to go back, Escape to close.

**Icons** are looked up in this order:

1. the item's `IconThemePath`;
2. the icon theme (`trayIconTheme`, else `gtk-icon-theme-name` from the GTK 3/4 `settings.ini`, else Adwaita) and its
   `Inherits` chain;
3. hicolor and `/usr/share/pixmaps`;
4. the item's pixmap;
5. a placeholder letter.

**Settings** in `[settings]`: `trayEnabled`, `trayMonitor` (`1` = first monitor, `0` = follow the selected one),
`trayIconPadding`, `trayIconSpacing`, `trayIconTheme`, `menuBorderColor`, `menuWidthMin`. The icon size is
`barHeight - 2 * trayIconPadding`.
