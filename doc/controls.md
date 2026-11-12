# Controls

[Back to README](../README.md)

Controls are bound to keys in the `[controls]` table of `config.default.toml`. The default modifier is Super. Press
Super+/ to show the bindings of the loaded config. Every control can also be run from the command line, see
[Command line](command-line.md).

Controls marked with a number take a tag from 1 to 9. On the keyboard the number is the key; on the command line it
is the argument, e.g. `nimdow-wl gototag 3`.

## Windows

| Default keys | Control | What it does |
| --- | --- | --- |
| Super+J | `focusNext` | Focuses the next window. |
| Super+K | `focusPrevious` | Focuses the previous window. |
| Super+Shift+J | `moveWindowNext` | Moves the window down the stack. |
| Super+Shift+K | `moveWindowPrevious` | Moves the window up the stack. |
| Super+F | `toggleFullscreen` | Toggles fullscreen for the selected window. |
| Super+Shift+Q | `destroySelectedWindow` | Closes the selected window. |

## Floating

Moving and resizing step by `floatingStep` pixels.

| Default keys | Control | What it does |
| --- | --- | --- |
| Super+Space | `toggleFloating` | Toggles the floating state of the selected window. |
| Super+C | `centerFloating` | Centers the selected floating window. |
| Super+Ctrl+H | `moveFloatingLeft` | Moves the floating window left. |
| Super+Ctrl+J | `moveFloatingDown` | Moves the floating window down. |
| Super+Ctrl+K | `moveFloatingUp` | Moves the floating window up. |
| Super+Ctrl+L | `moveFloatingRight` | Moves the floating window right. |
| Super+Ctrl+Shift+H | `resizeFloatingNarrower` | Makes the floating window narrower. |
| Super+Ctrl+Shift+J | `resizeFloatingTaller` | Makes the floating window taller. |
| Super+Ctrl+Shift+K | `resizeFloatingShorter` | Makes the floating window shorter. |
| Super+Ctrl+Shift+L | `resizeFloatingWider` | Makes the floating window wider. |

## Tags

| Default keys | Control | What it does |
| --- | --- | --- |
| Super+1 to 9 | `goToTag N` | Views tag N. |
| Super+Left | `goToLeftTag` | Views the tag on the left. |
| Super+Right | `goToRightTag` | Views the tag on the right. |
| Super+W | `goToPreviousTag` | Views the previously viewed tag. |
| Super+Shift+1 to 9 | `moveWindowToTag N` | Moves the selected window to tag N. |
| Super+Shift+Left | `moveWindowToLeftTag` | Moves the selected window to the tag on the left. |
| Super+Shift+Right | `moveWindowToRightTag` | Moves the selected window to the tag on the right. |
| Super+Shift+W | `moveWindowToPreviousTag` | Moves the selected window to the previously viewed tag. |
| Super+Ctrl+1 to 9 | `toggleTagView N` | Shows or hides tag N in the view. |
| Super+Ctrl+Shift+1 to 9 | `toggleWindowTag N` | Adds or removes the selected window on tag N. |

## Layout

| Default keys | Control | What it does |
| --- | --- | --- |
| Super+Z | `increaseMasterCount` | Adds a window to the master area. |
| Super+X | `decreaseMasterCount` | Removes a window from the master area. |
| Super+L | `increaseMasterWidth` | Widens the master area. |
| Super+H | `decreaseMasterWidth` | Narrows the master area. |
| Super+R | `rotateClients` | Rotates the windows clockwise, making the last window master. |
| Super+B | `toggleStatusBar` | Hides or shows the status bar on the selected monitor. |

## Monitors

| Default keys | Control | What it does |
| --- | --- | --- |
| Super+, | `focusPreviousMonitor` | Focuses the previous monitor. |
| Super+. | `focusNextMonitor` | Focuses the next monitor. |
| Super+Shift+, | `moveWindowToPreviousMonitor` | Moves the selected window to the previous monitor. |
| Super+Shift+. | `moveWindowToNextMonitor` | Moves the selected window to the next monitor. |

## Scratchpad

| Default keys | Control | What it does |
| --- | --- | --- |
| Super+Shift+S | `moveWindowToScratchpad` | Moves the selected window to the scratchpad. |
| Super+S | `popScratchpad` | Brings back the window most recently added to the scratchpad. |

## Launch

Programs are started by `[[startProcess]]` entries, not by controls. The defaults are:

| Default keys | Command | What it does |
| --- | --- | --- |
| Super+I | `$BROWSER` | Starts the browser. |
| Super+P | `fuzzel` | Starts the application launcher. |
| Super+Enter | `alacritty` | Starts the terminal. |

## Media & hardware

There are no default bindings. Bind keys such as `XF86AudioRaiseVolume` or `XF86MonBrightnessUp` to a
`[[startProcess]]` command, with `whileLocked = true` if they should work on the lock screen. See
[Configuration](configuration.md).

## Session

| Default keys | Control | What it does |
| --- | --- | --- |
| Super+/ | `toggleHotkeyOverlay` | Shows or hides the key bindings overlay. |
| Super+Esc | `lockSession` | Runs `lockCommand` and turns off all bindings until unlocked. |
| Super+Shift+R | `reloadConfig` | Reloads the config file. |
| Ctrl+Alt+Delete | `exitSession` | Exits nimdow-wl and River. |

## Mouse

The mouse bindings use `modKey` (default Super) and apply to the window under the pointer.

| Default buttons | What it does |
| --- | --- |
| Super+left drag | Moves the window. |
| Super+right drag | Resizes the window. |

## Command line only

`status` and `dumpState` have no key binding. They are the `--status` and `--dumpState` options, see
[Command line](command-line.md).
