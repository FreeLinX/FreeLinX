#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-live-boot.sh - boot the shipped base.iso and check the running system.
#
# The other suites check the installer's commands, its steps and its menus, and
# test-destructive-qemu.sh checks that those commands do the right thing to a
# real disk.  None of them check the system you get when you boot the disc
# without asking it to install anything, which is the first thing anyone does
# with it and the thing the disc is named after.
#
# That system had three defects, all of them "it works if you know the trick":
#
#   no console shell   var/service/shell/run waited for /dev/ttyS1 and exec'd
#                      nothing else.  No limine.conf in this tree - the one on
#                      the medium, the one setup-disk.sh writes - ever names
#                      ttyS1; they all say console=tty0 console=ttyS0,115200.
#                      runsvdir restarts a service that exits, so the service
#                      restarted forever and the system came up supervised,
#                      with no prompt on the screen and none on the serial line
#                      and nothing in the log but the same two lines repeating.
#
#   xsetup not found  the installer lives in /installer *on the medium*, and
#                      nothing mounted the medium.  So the documented procedure
#                      was "mount /dev/cdrom /mnt" first - a device name this
#                      system does not have - and then run the installer by its
#                      full path.  xsetup was not a command anywhere in the
#                      running system.
#
#   TERM on a serial  /etc/profile set TERM=xterm-256color on every console.  A
#      line            256-column terminfo entry on an 80x24 serial console
#                      makes every curses program render wrong.
#
# The test boots the real ISO - not -kernel and -initrd, because the medium
# auto-mount is a property of the volume id build-base.sh writes and of the CD
# device QEMU gives the guest, and neither exists in a -kernel boot.
#
# It drives the guest over the serial socket.  That is only possible because of
# the first fix: the reason the other suites inject a runit service instead of
# typing is recorded in test-destructive-qemu.sh, and it is "the rootfs's
# var/service/shell attaches its shell to /dev/ttyS1, so the socket has to be
# the second serial port or the shell is on the other one".  With a shell on
# ttyS0 - the port console= names, and the last one named, so the one the kernel
# and init also print to - the port the test watches is the port the shell is
# on.  The second thing that suite records, that xorg and ntpd make a shared
# console an unreliable place to read a result, is handled by markers rather
# than by quieting anything: each check echoes a unique token and the result is
# whatever arrives before the token.
#
# The virtual terminal is checked separately, by reading the VGA text buffer
# out of the guest's memory through the QEMU monitor.  A shell on ttyS0 and a
# shell on tty1 are different code paths, and the fix for this bug was in the
# list of ttys, so a test that only ever looked at the serial port would pass
# with tty1 still missing.
#
# usage: test-live-boot.sh [-i ISO] [-t TIMEOUT] [-v]

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ISO=$HERE/out/base.iso
TIMEOUT=240
VERBOSE=0
WORK=${TMPDIR:-/tmp}/flx-liveboot.$$

PASS=0
FAIL=0
LOG=$WORK/guest.log

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case $1 in
	-i) ISO=$2; shift 2 ;;
	-t) TIMEOUT=$2; shift 2 ;;
	-v) VERBOSE=1; shift ;;
	*) die "unknown option: $1" ;;
	esac
done

command -v qemu-system-x86_64 >/dev/null 2>&1 || die 'need qemu-system-x86_64'
command -v python3 >/dev/null 2>&1 || die 'need python3'
[ -f "$ISO" ] || die "no image at $ISO (run 'sh build-base.sh base' first)"

mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

step "booting $(basename "$ISO")"
say "  image   $ISO"
say "  timeout ${TIMEOUT}s"

# The serial line is a unix socket because it has to be both ends: read to see
# what the guest printed, written to give it something to run.  -serial
# file: can only do the first, and a serial console nobody can type at is a
# serial console that cannot be tested.
#
# -display none with a VGA adapter still present, so the guest allocates a
# framebuffer and the kernel brings up tty1 on it.  The text buffer at 0xb8000
# is read back through the monitor at the end.
rm -f "$WORK/con.sock" "$WORK/mon.sock"

timeout $((TIMEOUT + 60)) qemu-system-x86_64 \
	-cdrom "$ISO" \
	-m 2048 \
	-vga std \
	-display none \
	-chardev "socket,id=cons,path=$WORK/con.sock,server=on,wait=off" \
	-serial chardev:cons \
	-monitor "unix:$WORK/mon.sock,server=on,wait=off" \
	-no-reboot >"$WORK/qemu.log" 2>&1 &
QPID=$!

cleanup() {
	kill "$QPID" 2>/dev/null || :
	wait "$QPID" 2>/dev/null || :
}
trap 'cleanup; rm -rf "$WORK"' EXIT INT TERM

# The socket appears when QEMU has bound it, which is before the guest is even
# running.  Waiting for the file alone would connect to a guest that has not
# printed anything yet, so the driver waits for the console banner instead and
# that is the real readiness condition.
i=0
while [ ! -S "$WORK/con.sock" ]; do
	i=$((i + 1))
	[ "$i" -lt 100 ] || die 'the serial socket never appeared'
	sleep 0.1
done

step 'driving the guest'
set +e
python3 "$HERE/live-boot-driver.py" "$WORK/con.sock" "$LOG" "$TIMEOUT"
DRV=$?
set -e

if [ -f "$LOG" ]; then
	if [ "$VERBOSE" -eq 1 ]; then
		printf '\n---- guest console ----\n'
		tr -d '\r' <"$LOG"
		printf -- '---- end ----\n\n'
	fi
	cat "$LOG"
fi

# --- the virtual terminal ----------------------------------------------------
#
# Read out of the guest's own display, so this is what the kernel actually drew on
# - not a guess about what the console service should have done.
#
# base is a shell, so the console is vgacon drawing into the VGA text buffer.
# Reading it is how "tty1 has a shell" becomes a fact about the running system
# rather than an assumption: the serial line has been working the whole time,
# which is exactly why a dead screen was invisible until this check existed.
step 'reading the console out of the guest'
VGA_ERR=$WORK/vga.err
# One socket, the monitor: base has no desktop, so the console is vgacon on the
# VGA text buffer and reading that needs nothing from the guest.  What the reader
# finds and why it matters is in its own header.
TEXT=$(python3 "$HERE/live-boot-vga.py" "$WORK/mon.sock" 2>"$VGA_ERR")
VGA_RC=$?
# The reader's own explanation matters more than anything this script could say
# about a blank screen: it distinguishes vgacon bound with nothing written, from
# no console driver at all, from a framebuffer console that would put the text
# somewhere this reader cannot see.  Those need different fixes, so the reason is
# printed rather than summarised.
[ "$VGA_RC" -eq 0 ] || sed 's/^/  /' "$VGA_ERR" >&2
printf '%s\n' "$TEXT" | sed 's/^/  /'
[ "$VGA_RC" -eq 0 ] &&
	ok 'the graphical console has a shell on it' ||
	no 'the graphical console has a shell on it'

kill "$QPID" 2>/dev/null || :
wait "$QPID" 2>/dev/null || :

step 'result'
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$DRV" -eq 0 ] || FAIL=$((FAIL + 1))
if [ "$FAIL" -eq 0 ]; then
	say '  clean.'
	exit 0
fi
say "  $FAIL failed."
exit 1
