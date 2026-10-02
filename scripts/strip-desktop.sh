#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# strip-desktop.sh - take the desktop out of the rootfs, so base is a shell.
#
# FreeLinX base is the minimal image, in the sense Ubuntu minimal or Fedora
# minimal is: a shell on tty1, an installer, and no desktop. Nothing graphical
# is started at boot and no graphical software is carried.
#
# This script does the removal as a list, not as a search. A search would take
# whatever happened to match today and would follow a renamed file into the next
# build, so the list is here where it can be read and argued with.
#
# Two things are deliberately kept even though they look graphical or huge:
#
#   usr/share/zoneinfo   1.4 MiB. The installer writes /etc/localtime from it
#                        and the install's own test checks that the ~600 zone
#                        files survive the copy as hard links. Dropping it makes
#                        the installer write a dangling symlink.
#   the framebuffer      Nothing here is kept "for the desktop". The framebuffer
#     console            console is what makes a shell visible on a screen at
#                        all; without it the graphical console is black and the
#                        system is serial-only. That is the console, not a
#                        desktop, and it is the same 25 lines of kernel config
#                        either way.
#
# Run from anywhere:  sh base/scripts/strip-desktop.sh [--check]
#
# --check reports what would go and changes nothing, which is what to run first.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${FREELINX_ROOTFS:-$(cd "$HERE/../.." && pwd)/src/rootfs}
CHECK=0
[ "${1:-}" = --check ] && CHECK=1

[ -d "$ROOT" ] || { printf 'strip-desktop: no rootfs at %s\n' "$ROOT" >&2; exit 1; }
[ -d "$ROOT/usr/bin" ] || {
	printf 'strip-desktop: %s does not look like a rootfs\n' "$ROOT" >&2
	exit 1
}

# --- what goes ---------------------------------------------------------------
#
# Grouped by why, because "why is mpv in a shell image" has to have an answer
# and "a list" is only an answer if the list is legible.

# The X server and the window manager that used to start at boot.
X_SERVER='usr/bin/Xorg usr/lib/xorg usr/share/X11 etc/X11
	usr/bin/openbox usr/lib/openbox usr/share/openbox
	usr/etc/fonts'

# Desktop shells, panels and their helpers.
DESKTOP_SHELL='usr/bin/flxinstall-gui usr/bin/flxpanel usr/bin/flxbar-bottom
	usr/bin/flxbg usr/bin/flxshot usr/bin/i3status usr/bin/lemonbar
	usr/bin/openbox usr/bin/dmenu usr/bin/dzen2 usr/bin/sway usr/bin/i3'

# X clients: programs that open an X window and have nothing to do without a
# server.
X_CLIENTS='usr/bin/xeyes usr/bin/xclock usr/bin/xcalc usr/bin/xmag usr/bin/xrandr
	usr/bin/setxkbmap usr/bin/xkbcomp usr/bin/xdpyinfo usr/bin/xprop
	usr/bin/xwininfo usr/bin/xev usr/bin/xkill usr/bin/xloadimage
	usr/bin/urxvt usr/bin/xterm usr/bin/uxterm
	usr/bin/xdemo usr/bin/xsetroot usr/bin/glxgears
	usr/share/fonts usr/bin/fontconfig'

# st, the suckless terminal, and why it is here rather than kept.
#
# st is a terminal emulator, and a minimal image is about terminals, so this looks
# wrong.  It is not: st 0.9.2 has X11 compiled into it structurally, not behind a
# flag.  x.c is in the object list unconditionally -
#
#     OBJ = $(SRC:.c=.o)
#
# - and includes X11/Xlib.h, X11/cursorfont.h and X11/Xft/Xft.h at the top with no
# #ifdef around any of it.  Built with X, it opens a window on a display; there is
# no display here, so it opens nothing.  Not a flag that can be cleared, a new
# input backend that has to be written.
#
# tmux is the opposite case and stays: it is statically linked with no shared
# library at all, and it runs on a serial line.  A multiplexer that needs no
# display is not a desktop program.
#
# Giving st a tty backend is real work - st.c drives the pty itself (ioctl
# TIOCSCTTY, TIOCSWINSZ) and x.c is where all its input arrives - and it belongs
# to the st port rather than to a strip script.  Until that exists, st in this
# image is dead weight.
X_TERMINALS='usr/bin/st'

# Browsers, viewers and players. Big, and none of them can open without X.
MEDIA_GUI='usr/bin/mpv usr/bin/mupdf usr/bin/mupdf-x11 usr/bin/netsurf
	usr/bin/dillo usr/bin/links usr/bin/elinks usr/bin/w3m usr/bin/lynx
	usr/bin/ffmpeg usr/bin/ffplay usr/bin/ffprobe'

# The runit service that started the desktop. This is the one that matters most:
# with it in place, a minimal image boots and launches a window manager.
X_SERVICE='var/service/xorg'

ALL="$X_SERVER
$DESKTOP_SHELL
$X_CLIENTS
$X_TERMINALS
$MEDIA_GUI
$X_SERVICE"

# --- report or do ------------------------------------------------------------

gone=0
kept=0

for _p in $ALL; do
	[ -e "$ROOT/$_p" ] || [ -L "$ROOT/$_p" ] || continue
	if [ "$CHECK" -eq 1 ]; then
		_sz=$(du -sh "$ROOT/$_p" 2>/dev/null | cut -f1 || printf '?')
		printf '  would remove  %-34s %s\n' "$_p" "$_sz"
		gone=$((gone + 1))
		continue
	fi
	rm -rf "$ROOT/$_p"
	printf '  removed       %s\n' "$_p"
	gone=$((gone + 1))
done

	# Whatever is left, listed. shell, mdevd, ntpd and dbus are what a minimal
	# system needs; dbus is not a desktop requirement, several shell tools
	# expect its socket to exist. Anything else is worth a look, because a
	# service that is not one of those four has no obvious reason to be in a
	# minimal image - but it is only reported, never removed. Guessing at what a
	# service is for from its name is how a working image loses a service.
	for _s in "$ROOT"/var/service/*; do
		[ -d "$_s" ] || continue
		_name=$(basename "$_s")
		case $_name in
		shell|mdevd|ntpd|dbus) ;;
		*)
			[ "$CHECK" -eq 0 ] && printf '  left          var/service/%s\n' "$_name"
			;;
		esac
	done

# --- the check that matters --------------------------------------------------

# The one thing that would make this a lie: a service that starts X still present
# after the strip.
#
# Only in the doing pass. In --check it is being reported as about to be removed,
# so finding it there is the expected result and treating it as a failure would
# make --check unusable - it always exits 1, which reads as "the strip is broken"
# when in fact the strip has not run yet. That is how this went unnoticed: the
# check reported a failure on a clean tree, so its failure stopped meaning
# anything.
_left=$(ls "$ROOT/var/service" 2>/dev/null | tr '\n' ' ' || printf '')
if [ "$CHECK" -eq 0 ]; then
	case "$_left" in
	*xorg*)
		printf '\nstrip-desktop: var/service/xorg is still there\n' >&2
		exit 1
		;;
	esac
fi

printf '\n'
if [ "$CHECK" -eq 1 ]; then
	printf '  %d path(s) would go.\n' "$gone"
else
	printf '  %d path(s) removed.\n' "$gone"
fi
# Named before the removal on purpose, so the report says what will be left
# rather than what is left now: in --check nothing has run, and printing the
# current list shows the xorg service that is about to go and reads as though
# the check found a problem.
if [ "$CHECK" -eq 1 ]; then
	printf '  runit services to keep: %s\n' \
		"$(ls "$ROOT/var/service" 2>/dev/null | grep -vx xorg | tr '\n' ' ')"
else
	printf '  runit services left:   %s\n' "${_left:-none}"
fi
printf '  zoneinfo kept:       %s\n' \
	"$([ -d "$ROOT/usr/share/zoneinfo" ] && echo yes || echo 'NO - the installer needs it')"
