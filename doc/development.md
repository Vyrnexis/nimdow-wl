# Development

[Back to README](../README.md)

For an overview of the code, see [Architecture](architecture.md).

## Nimble tasks

| Task | What it does |
| --- | --- |
| `nimble debug` | debug build to `bin/nimdow-wl` |
| `nimble release` | release build |
| `nimble test` | run the unit tests (needs `nimtest`) |
| `nimble wlgen` | regenerate the Wayland protocol bindings from `protocol/*.xml` |
| `nimble e2e` | build and run the end-to-end tests |
| `nimble nested` | build a debug binary and run it nested (see below) |
| `nimble lint` | run `nimpretty` |

## Nested session

`bash tools/dev-nested.sh` (or `nimble nested`) builds a debug binary and runs it in a River window nested in your
current Wayland session, using `config.default.toml`.

Set `NIMDOW_NO_SESSION=1` to skip the systemd/D-Bus session setup. The nested runs and the end-to-end tests do this,
so they do not touch your real user session.

## End-to-end tests

```sh
bash tests/e2e/run.sh [-o outdir] [-b] [-s scenario,...]
```

Runs nimdow-wl in a nested River with `tests/e2e/config.toml`. It needs `river`, `grim`, `alacritty`, `jq`,
`dbus-run-session`, python3 with PyGObject and a running Wayland session.

- Input is injected through the virtual keyboard and pointer protocols by `bin/nimdowinput` (built by `-b` or on
  first use).
- Results are asserted through `nimdow-wl --dumpState`.
- The nested River runs in a private D-Bus session with `tests/e2e/fake_sni.py` as fake tray items.
- Screenshots, logs and `results.txt` go to the output directory (default `./e2e-out`).

## Fresh install test

```sh
sudo tools/fresh-install-test.sh [--keep]
```

Tests the AUR packages on a clean system: it pacstraps a minimal Arch into a throwaway systemd-nspawn container,
installs `nimdow-wl-desktop-git` with paru as a new user, boots the container and runs the desktop headless. It checks
the first-run config, autostart, session targets, portal and logout. Results go to `/var/tmp/nimdow-wl-test-result`.
It needs about 2 GB of disk and network access.
