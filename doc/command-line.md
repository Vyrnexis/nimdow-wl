# Command line

[Back to README](../README.md)

```
nimdow-wl                      start nimdow-wl (as the River window manager client)
nimdow-wl -c, --config <file>  use another config file
nimdow-wl -v, --version        print version information
nimdow-wl --status "text"      set the status text of the running instance
nimdow-wl --dumpState [file]   write the running instance's state as JSON
                               (default $XDG_RUNTIME_DIR/nimdow-wl-state.json)
```

## Running controls

Every control that can be bound to a key can also be run through the same client, e.g. from scripts or another
program's key bindings. Dashes are optional and case is ignored, so these all work:

```sh
nimdow-wl --toggle-floating
nimdow-wl togglefloating
nimdow-wl gototag 3
nimdow-wl --lock-session
nimdow-wl --toggle-hotkey-overlay
nimdow-wl --exit-session
```

`man nimdow-wl` lists all controls, and [Controls](controls.md) lists them with their default keys.

## Inspecting state

`nimdow-wl --dumpState` writes the running instance's state as JSON. Besides windows and tags it includes the input
device report, `locked` and `overlayVisible`, which helps when debugging config or input settings.
