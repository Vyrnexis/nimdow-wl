#!/bin/bash
# Fresh-install test for the AUR packages, in a throwaway systemd-nspawn container.
#
#   sudo tools/fresh-install-test.sh [--keep]
#
# 1. pacstraps a clean Arch (core + extra only, official mirrors) into /var/tmp
# 2. as a normal user: installs paru-bin, then `paru -S nimdow-wl-desktop-git` from the AUR
# 3. boots the container, logs that user in, runs River headless with nimdow-wl and checks
#    the first-run config copy, autostart, session targets, IPC, portal and exitsession
# 4. powers the container off and deletes it (--keep leaves it for inspection)
#
# Results (summary, logs, screenshot) go to /var/tmp/nimdow-wl-test-result.
# Needs ~2 GB disk, network, and arch-install-scripts (installed if missing).
set -uo pipefail

[ "$EUID" = 0 ] || exec sudo "$0" "$@"

KEEP=0; [ "${1:-}" = --keep ] && KEEP=1
WORK=/var/tmp/nimdow-wl-test
ROOT=$WORK/root
OUT=/var/tmp/nimdow-wl-test-result
MACHINE=nimdowtest
OWNER=${SUDO_USER:-root}
MIRROR='Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch'

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*"; exit 1; }

cleanup() {
  if machinectl show "$MACHINE" >/dev/null 2>&1; then
    machinectl poweroff "$MACHINE" 2>/dev/null
    for _ in $(seq 30); do machinectl show "$MACHINE" >/dev/null 2>&1 || break; sleep 1; done
    machinectl terminate "$MACHINE" 2>/dev/null
    sleep 1
  fi
  if [ "$KEEP" = 0 ] && [ -d "$WORK" ] && ! machinectl show "$MACHINE" >/dev/null 2>&1; then
    rm -rf --one-file-system "$WORK"
  fi
  [ -d "$OUT" ] && chown -R "$OWNER": "$OUT"
}
trap cleanup EXIT

machinectl show "$MACHINE" >/dev/null 2>&1 && die "a container named $MACHINE is already running"
command -v pacstrap >/dev/null || pacman -S --needed --noconfirm arch-install-scripts || die "could not install arch-install-scripts"

rm -rf --one-file-system "$WORK" "$OUT"
mkdir -p "$ROOT" "$OUT"

# --- 1. clean Arch ------------------------------------------------------------------
say "pacstrap: base base-devel git sudo (official Arch repos only)"
printf '%s\n' "$MIRROR" > "$WORK/mirrorlist"
cat > "$WORK/pacman.conf" <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5
[core]
Include = $WORK/mirrorlist
[extra]
Include = $WORK/mirrorlist
EOF
pacstrap -K -M -C "$WORK/pacman.conf" "$ROOT" base base-devel git sudo || die "pacstrap failed"
printf '%s\n' "$MIRROR" > "$ROOT/etc/pacman.d/mirrorlist"
echo "$MACHINE" > "$ROOT/etc/hostname"

nsp() { systemd-nspawn -q -D "$ROOT" --resolv-conf=copy-host "$@"; }
nsp useradd -m -G wheel tester || die "useradd failed"
echo 'tester ALL=(ALL) NOPASSWD: ALL' > "$ROOT/etc/sudoers.d/tester"

# --- 2. install from the AUR, as a new user would --------------------------------------
say "as user tester: paru-bin, then paru -S nimdow-wl-desktop-git (this takes a while)"
nsp --user=tester --chdir=/home/tester bash -c '
  set -e
  git clone -q https://aur.archlinux.org/paru-bin.git
  (cd paru-bin && makepkg -si --noconfirm)
  paru -S --noconfirm --skipreview nimdow-wl-desktop-git
' 2>&1 | tee "$OUT/install.log"
[ "${PIPESTATUS[0]}" = 0 ] || die "AUR install failed, see $OUT/install.log"
nsp pacman -Q > "$OUT/installed-packages.txt"

# --- 3. boot, log in, run the desktop headless -------------------------------------------
cat > "$ROOT/home/tester/nimtest.sh" <<'EOF'
#!/bin/bash
R=~/result; rm -rf "$R"; mkdir -p "$R"
pass() { echo "PASS  $*" >> "$R/summary"; }
fail() { echo "FAIL  $*" >> "$R/summary"; }
warn() { echo "WARN  $*" >> "$R/summary"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }
dump() { rm -f "$R/state.json"; nimdow-wl --dumpState "$R/state.json" >/dev/null 2>&1; sleep 0.5; [ -s "$R/state.json" ]; }

[ -e ~/.config/nimdow-wl/config.toml ] && fail "a user config already existed before first login"
check "login session has XDG_RUNTIME_DIR" test -d "$XDG_RUNTIME_DIR"

export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY DISPLAY
river -c nimdow-wl > "$R/river.log" 2>&1 &
RPID=$!

for _ in $(seq 40); do dump && break; sleep 0.5; done
check "nimdow-wl started and answers IPC (--dumpState)" test -s "$R/state.json"
check "bar is visible" grep -Eq '"barVisible": ?true' "$R/state.json"
check "first-run config copied from /etc/xdg" cmp -s /etc/xdg/nimdow-wl/config.toml ~/.config/nimdow-wl/config.toml

sleep 10   # autostart + session units
for p in mako swaybg nimdow-wl-statu; do check "autostart: $p running" pgrep -u "$(id -u)" -x "$p"; done
check "autostart: polkit-gnome agent running" pgrep -u "$(id -u)" -f polkit-gnome-authentication-agent-1
check "nimdow-wl-session.target active" systemctl --user is-active nimdow-wl-session.target
check "graphical-session.target active" systemctl --user is-active graphical-session.target
check "WAYLAND_DISPLAY exported to systemd" sh -c 'systemctl --user show-environment | grep -q ^WAYLAND_DISPLAY='
check "xdg-desktop-portal answers" busctl --user --timeout=20 call org.freedesktop.portal.Desktop \
  /org/freedesktop/portal/desktop org.freedesktop.DBus.Properties Get ss org.freedesktop.portal.Settings version

sock=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | head -1)
export WAYLAND_DISPLAY=$sock
# kitty needs OpenGL; a headless pixman output may not offer it, so only warn.
kitty --title nimtest-kitty > "$R/kitty.log" 2>&1 &
sleep 6
if dump && grep -q nimtest-kitty "$R/state.json"; then pass "kitty opens and is managed"
else warn "kitty did not map (expected without a GPU; see kitty.log)"; fi
grim "$R/screen.png" 2>> "$R/grim.log" && pass "screenshot taken (grim)" || warn "grim screenshot failed"

nimdow-wl exitsession >/dev/null 2>&1
for _ in $(seq 20); do kill -0 "$RPID" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$RPID" 2>/dev/null; then fail "nimdow-wl exitsession ends river"; kill "$RPID"; else pass "nimdow-wl exitsession ends river"; fi

journalctl --user -b --no-pager > "$R/user-journal.log" 2>&1
cp ~/.config/nimdow-wl/config.toml "$R/" 2>/dev/null
echo done > "$R/finished"
EOF
chmod 755 "$ROOT/home/tester/nimtest.sh"

say "booting the container"
systemd-nspawn -q -b -D "$ROOT" -M "$MACHINE" --resolv-conf=copy-host --console=passive \
  > "$OUT/boot.log" 2>&1 </dev/null &
for _ in $(seq 60); do
  systemd-run -M "$MACHINE" -q --wait -P true >/dev/null 2>&1 && break
  sleep 1
done
systemd-run -M "$MACHINE" -q --wait -P systemctl is-system-running --wait >/dev/null 2>&1

say "running the desktop headless as tester (about 30 s)"
machinectl shell tester@"$MACHINE" /home/tester/nimtest.sh > "$OUT/test-shell.log" 2>&1 </dev/null
cp -r "$ROOT/home/tester/result/." "$OUT/" 2>/dev/null

# --- 4. report -------------------------------------------------------------------------
say "results ($OUT)"
if [ -f "$OUT/summary" ]; then cat "$OUT/summary"; else echo "FAIL  test script produced no summary (see $OUT/test-shell.log)"; fi
[ -f "$OUT/finished" ] || echo "FAIL  test script did not finish"
if [ -f "$OUT/finished" ] && ! grep -q '^FAIL' "$OUT/summary"; then exit 0; fi
exit 1
