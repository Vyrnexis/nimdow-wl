---
name: Bug report
about: Create a report to help us improve
title: ''
labels: bug
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Start nimdow with '...' (login manager session, `river -c nimdow`, nested River, ...)
2. Press '....' / run '....'
3. See error

**Expected behavior**
A clear and concise description of what you expected to happen.

**Environment**
- nimdow version (`nimdow -v`):
- River version (`river -version`):
- Distro and how nimdow was installed (AUR/`nimdow-wayland-git`, from source):
- GPU / driver, number of monitors and scale factors:
- Affected application(s), and whether they are native Wayland or XWayland:

**Config**
Relevant parts of your `~/.config/nimdow/config.toml` (or say that you use the default).

**`nimdow --dumpState` output**
If the bug involves windows, tags, monitors, the bar or the tray, run `nimdow --dumpState state.json` while it happens and attach the file.

**Logs**
nimdow logs to stderr. Attach the relevant output, e.g. `journalctl --user -b | grep -i nimdow`, or the output of `river -log-level debug -c nimdow`.

**Screenshots**
If applicable, add screenshots to help explain your problem.

**Additional context**
Add any other context about the problem here.
