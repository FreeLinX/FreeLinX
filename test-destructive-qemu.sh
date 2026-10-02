#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-destructive-qemu.sh - run the real installer against a real disk.
#
# The other three test suites stop short of the only part that cannot be checked
# without privileges this build host does not have.  test-destructive.sh runs the
# installer's own commands against image files with the rootfs's own binaries,
# which proves the commands are right; it cannot prove that partitioning a block
# device, formatting it, mounting the result and writing a boot sector work,
# because all four want root and a /dev/loop* node, and this host has neither.
#
# So the test moves the problem into a virtual machine, where it is not a
# problem: the guest runs as uid 0 and /dev/vda is a real block device.  Every
# step the installer takes is a real step on a real device, and the result is
# checked afterwards by reading the partitions back with blkid, dd and mount -
# never by believing the installer's own report of what it did.
#
# How the guest is made to run the test
# -------------------------------------
# Not by typing at the console.  Three attempts at that failed, all for reasons
# worth recording:
#
#   - the rootfs's var/service/shell attaches its shell to /dev/ttyS1, so the
#     socket has to be the *second* serial port or the shell is on the other
#     one and the test watches an empty line
#   - the first form, `printf ... | socat`, sends its one line, hits end of
#     input and shuts the connection down at once, so the command only lands if
#     the guest shell happens to already be reading
#   - when it does connect, xorg and the ntpd service both write to the console,
#     and a console shared with an X server failing to find a framebuffer is
#     not a reliable place to read a test result from
#
# Instead the test is injected as a runit service.  Linux unpacks a concatenated
# series of initramfs archives, so a 250-byte extra archive appended to the
# image adds one service directory to a 218 MB filesystem without unpacking or
# repacking anything.  The service runs the test, the results go to the serial
# console, and the console is a plain file - which is a thing that can be
# grepped, unlike a socket.
#
# What this proves, and what it does not
# --------------------------------------
#   proves   flxpart writes a table mkfs and mount can use; the ESP is FAT32 and
#            BOOTX64.EFI lands on it and not on the ext4 root; the rootfs copy
#            preserves hard links; the fstab names devices by UUID and the UUID
#            is this disk's; Limine's BIOS stages reach the drive's own sectors
#   does not prove the installed system boots from that disk.  --boot-check
#            does that, in a second QEMU run with the medium detached.
#
# usage: test-destructive-qemu.sh [-k KERNEL] [-i INITRAMFS] [-s MB]
#                                 [--boot-check] [-n] [-v]

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC=$ROOT/src
OUT=$HERE/out
LIMINE=$ROOT/drivers/bootloader/limine-binary
WORK=${TMPDIR:-/tmp}/flx-dtest.$$

KERNEL=$SRC/rootfs/boot/vmlinuz
INITRD=
DISK_MB=4096
BUILD=1
VERBOSE=0
BOOTCHECK=0
KEEP=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case $1 in
	-k) KERNEL=$2; shift ;;
	-i) INITRD=$2; shift ;;
	-s) DISK_MB=$2; shift ;;
	--boot-check) BOOTCHECK=1 ;;
	-n) BUILD=0 ;;
	-v) VERBOSE=1 ;;
	-K) KEEP=1 ;;
	-m|--mode) MODE=$2; shift ;;
	-h) sed -n '2,48p' "$0" | sed 's/^# \?//'; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
	shift
done

# Which install to run.  sys is the install that has to work; data is a
# different layout for a disk that holds state, and it is checked separately
# because the two cannot be checked against one disk - each erases it.
#
# Assigned after the option loop, unconditionally.  It was assigned inside the
# loop only, so `-M data` set it and then this line overwrote it with the
# default - and the run then installed sys, passed all 31 of sys's checks, and
# reported
#
#   passed: 31  failed: 0
#
# for a test that had been asked to do something else entirely.  Nothing in the
# output said data; nothing said so was wrong either.  A default that silently
# beats the option is worse than no default at all.
#
# So there is no unconditional assignment here, and the default is applied with
# `${MODE+x}` - "is it set at all" - rather than `[ -z "$MODE" ]`.  That
# distinction is the whole fix and it is easy to get wrong twice:
#
#   MODE=sys after the loop   overwrites whatever -m set, which is the bug
#   MODE=    after the loop   the same bug: a bare assignment empties the
#                             variable whatever it held, so -m data becomes ""
#   [ -z "$MODE" ]            cannot tell "not given" from "given and empty",
#                             so it defaults over a real answer
#
# `${MODE+x}` is set for an empty-but-given value and unset only when the
# variable was never assigned, which is exactly the distinction wanted.
if [ -z "${MODE+x}" ]; then
	MODE=sys
fi

case $MODE in
sys|data) ;;
*) die "--mode must be sys or data, not '$MODE'" ;;
esac

PASS=0
FAIL=0

cleanup() {
	if [ "$KEEP" = 1 ]; then
		say ''
		say "work directory kept: $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT INT TERM

# --- what we need ------------------------------------------------------------

command -v qemu-system-x86_64 >/dev/null 2>&1 ||
	die 'qemu-system-x86_64 not found; this test runs the installer in a VM'
command -v xorriso >/dev/null 2>&1 || die 'xorriso not found'
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
[ -f "$HERE/guest-install.sh" ] || die "missing $HERE/guest-install.sh"

# The archive tools are the rootfs's own bsdtar and gzip, for the same reason
# everything else here avoids GNU: the non-GNU property of a shipped artifact
# should not stop being true because of how the test that checks it is written.
TAR=$SRC/rootfs/bin/tar
GZIP=$SRC/rootfs/bin/gzip
LOADER=$ROOT/TestForBase/toolchain/x86_64-linux-musl/lib/ld-musl-x86_64.so.1
[ -f "$TAR" ] || die "no bsdtar at $TAR"
[ -f "$GZIP" ] || die "no gzip at $GZIP"
[ -f "$LOADER" ] || die "no musl loader at $LOADER"

mkdir -p "$WORK"

# --- the image the guest boots ----------------------------------------------
#
# The normal profile, because that is the one with flxpart, mkfs.ext4,
# mkfs.fat, tar and limine in it.  The rescue profile deliberately has none of
# those and cannot install anything.
if [ -z "$INITRD" ]; then
	INITRD=$OUT/initramfs-normal.img.gz
	if [ "$BUILD" = 1 ] && [ ! -f "$INITRD" ]; then
		step 'building the normal initramfs (a few minutes)'
		(cd "$SRC" && sh scripts/initramfs.sh -o "$INITRD" normal) ||
			die 'the normal initramfs did not build'
	fi
fi
[ -f "$INITRD" ] || die "initramfs not found: $INITRD"

say "  kernel     $KERNEL"
say "  initramfs  $INITRD ($(wc -c <"$INITRD" | tr -d ' ') bytes)"

# --- inject the test as a runit service -------------------------------------

step 'injecting the test as a runit service'
ISTAGE=$WORK/inject
mkdir -p "$ISTAGE/var/service/flx-dtest"
# MODE is the host's and is substituted here; every other dollar in the body is
# the guest's and is left alone, which is what the quotes below are for.
cat >"$ISTAGE/var/service/flx-dtest/run" <<'RUNEOF'
#!/bin/sh
# Injected by test-destructive-qemu.sh.  Mounts the installer medium, runs the
# destructive install test once, and then holds still: a service that exits is
# restarted by runsvdir, which would run the installer a second time on a disk
# it has already erased.
# FLXHOSTMODE is the host's MODE, written into this script by the sed below.  It
# is a separate variable from the one the guest installer reads so that the
# substitution has one unambiguous target to replace.
FLXHOSTMODE=sys
MODE=$FLXHOSTMODE
MNT=/cdrom
mkdir -p "$MNT"

# The marker goes in /tmp because setup-disk.sh excludes /tmp from the copy:
# a marker left at / would be installed onto the disk as a stray file.
if [ -f /tmp/flx-dtest.already-ran ]; then
	echo 'flx-dtest: already ran, holding'
else
	: >/tmp/flx-dtest.already-ran
	mounted=
	for d in /dev/sr0 /dev/sr1 /dev/cdrom /dev/vdb; do
		[ -b "$d" ] || continue
		if mount -t iso9660 -o ro "$d" "$MNT" 2>/dev/null; then
			mounted=$d
			break
		fi
	done
	if [ -z "$mounted" ]; then
		echo "flx-dtest: FATAL the installer medium did not mount"
	else
		echo "flx-dtest: medium $mounted at $MNT"

		# Wait for the disk and its partition nodes.
		#
		# The partition nodes are created by the device manager from kernel
		# uevents, so they appear a moment after boot rather than at it.  A
		# person boots base.iso and then types xsetup, which is minutes, so
		# this ordering never bites them; a test that fires the installer as
		# soon as it has a shell does hit it, and the symptom is
		#
		#   mount: mount /dev/vda3 on /mnt/flx: No such device
		#
		# which reads as a broken installer rather than a race, because the
		# filesystem drivers are built into this kernel and there is nothing
		# to load.  So the nodes are waited for here, and the failure mode is
		# named if they never turn up.
		#
		# The count waited for is the mode's, not a constant.  A data disk has
		# exactly one partition and a sys install three, so waiting for vda3 on
		# a disk that will only ever have vda1 is a wait that never ends and the
		# installer never runs at all.
		[ -x /sbin/mdevd-coldplug ] && /sbin/mdevd-coldplug >/dev/null 2>&1
		if [ "$MODE" = sys ]; then
			want_parts=3
		else
			want_parts=1
		fi
		_waited=0
		while [ "$_waited" -lt 60 ]; do
			[ -b /dev/vda ] || { _waited=$((_waited + 1)); sleep 1; continue; }
			_found=0
			_i=1
			while [ "$_i" -le "$want_parts" ]; do
				[ -b "/dev/vda$_i" ] || break
				_found=$_i
				_i=$((_i + 1))
			done
			if [ "$_found" -eq "$want_parts" ]; then
				echo "flx-dtest: /dev/vda and its $_found partitions are present"
				break
			fi
			_waited=$((_waited + 1))
			sleep 1
		done
		if [ "$_waited" -ge 60 ]; then
			echo "flx-dtest: FATAL /dev/vda never reached $want_parts partitions"
			echo "flx-dtest: /dev holds: $(ls /dev | tr '\n' ' ')"
		fi

		echo "flx-dtest: mode $MODE"
		FLX_TEST_MODE=$MODE sh "$MNT/guest-install.sh"
		echo "flx-dtest: guest-install.sh exited $?"
	fi
fi

while :; do sleep 60; done
RUNEOF
# The heredoc above is quoted, so the host's $MODE did not reach it.  Written
# afterwards instead of substituted into the heredoc, which keeps every dollar in
# the body the guest's and makes this the one place a value crosses over.
if ! sed "s|^FLXHOSTMODE=.*|FLXHOSTMODE=$MODE|" \
	"$ISTAGE/var/service/flx-dtest/run" >"$ISTAGE/var/service/flx-dtest/run.new"; then
	die 'could not write the mode into the injected service'
fi
mv "$ISTAGE/var/service/flx-dtest/run.new" "$ISTAGE/var/service/flx-dtest/run"
chmod 755 "$ISTAGE/var/service/flx-dtest/run"

# And check it landed, rather than trusting that it did.  A mode that silently
# stayed 'sys' while the run says it is testing data produces a perfect sys
# install, all its checks pass, and the log says "passed: 31 failed: 0" for a
# run that tested the wrong thing - the one result that looks like success and
# means nothing.  It did exactly that here.
_got=$(sed -n 's/^FLXHOSTMODE=//p' "$ISTAGE/var/service/flx-dtest/run")
[ "$_got" = "$MODE" ] ||
	die "the mode did not reach the injected service: asked for $MODE, the script says ${_got:-nothing}"
say "  mode        $MODE"

# xorg and ntpd write to the console, and xorg in particular cannot find a
# framebuffer in a headless VM, so runsvdir restarts it and it fills the log
# with the same 400 lines a second.  runit already has the answer for a service
# that is not wanted right now: a `down` file in the service directory.  These
# are put down only for this test, only here, and the injected archive is
# applied after the real one, so the shipped image is not touched.
for _svc in xorg ntpd; do
	if [ -d "$SRC/rootfs/var/service/$_svc" ]; then
		mkdir -p "$ISTAGE/var/service/$_svc"
		: >"$ISTAGE/var/service/$_svc/down"
	fi
done

# Sorted, fixed ownership and mtime, exactly as initramfs.sh writes the real
# image, so the injected archive is as reproducible as the thing it is added to.
(
	cd "$ISTAGE" &&
		find . -mindepth 1 -print0 | LC_ALL=C sort -z |
			"$LOADER" "$TAR" \
				--format=newc --null --no-recursion \
				--uid 0 --gid 0 --uname root --gname root \
				--mtime '@946684800' \
				--no-xattrs --no-acls --no-fflags \
				-cf - -T -
) >"$WORK/extra.cpio" || die 'could not build the injected archive'
"$GZIP" -9 -n -c "$WORK/extra.cpio" >"$WORK/extra.cpio.gz" ||
	die 'could not compress the injected archive'

cat "$INITRD" "$WORK/extra.cpio.gz" >"$WORK/combined.img.gz" ||
	die 'could not concatenate the initramfs'
say "  injected $(wc -c <"$WORK/extra.cpio.gz" | tr -d ' ') bytes onto $(wc -c <"$INITRD" | tr -d ' ')"

# --- stage the installer on a small ISO -------------------------------------
#
# The installer travels on a medium, not in the initramfs, because that is how
# it is run: base.iso puts it in /installer and the user mounts the disc.  A
# test that put it somewhere else would not be testing the thing that ships.
#
# The initramfs goes on the medium for the same reason.  The installer copies it
# to the installed disk, because FreeLinX boots by loading that file and running
# the runit init inside it - a running system has unpacked it and keeps no copy,
# so the medium is the only place it exists.  A medium without it produces an
# installed disk with a kernel and no system, which is the failure this step is
# here to catch.
STAGE=$WORK/stage
mkdir -p "$STAGE/boot"

cp "$KERNEL" "$STAGE/boot/bzImage"
cp "$INITRD" "$STAGE/boot/initramfs.img.gz"
cp "$HERE/xsetup" "$STAGE/installer-xsetup"
mkdir -p "$STAGE/installer/lib" "$STAGE/installer/xsetup.d"
cp "$HERE/xsetup" "$STAGE/installer/xsetup"
cp "$HERE"/lib/*.sh "$STAGE/installer/lib/"
cp "$HERE"/xsetup.d/*.sh "$STAGE/installer/xsetup.d/"
cp "$HERE/guest-install.sh" "$STAGE/guest-install.sh"
chmod +x "$STAGE/installer/xsetup" "$STAGE/guest-install.sh"

KRD=$WORK/boot.iso
step 'composing the installer medium'
xorriso -as mkisofs -R -J -V FREELINX "$STAGE" -o "$KRD" >/dev/null 2>&1 ||
	die 'could not build the installer medium'

# --- the scratch disk --------------------------------------------------------

DISK=$WORK/disk.raw
step "creating a ${DISK_MB}MB scratch disk"
dd if=/dev/zero of="$DISK" bs=1M count="$DISK_MB" status=none ||
	die 'could not create the scratch disk'

# --- run it ------------------------------------------------------------------
#
# The disk is not snapshotted: it has to keep what was written to it, because
# --boot-check boots from it afterwards.
#
# console=ttyS0 and the console goes to a file.  No socket and no typing, so
# nothing here depends on the guest having a shell at the right moment.
step 'running the installer (a few minutes)'
rm -f "$WORK/guest.log"

timeout 2400 qemu-system-x86_64 \
	-kernel "$KERNEL" \
	-initrd "$WORK/combined.img.gz" \
	-append 'rdinit=/init console=ttyS0,115200 loglevel=3' \
	-m 2048 \
	-drive "file=$DISK,format=raw,if=virtio,cache=writeback" \
	-cdrom "$KRD" \
	-serial "file:$WORK/guest.log" \
	-display none \
	-no-reboot >/dev/null 2>&1 &
QPID=$!

_done=0
_i=0
while [ "$_i" -lt 400 ]; do
	if grep -qa 'FLX-TEST-DONE' "$WORK/guest.log" 2>/dev/null; then
		_done=1
		break
	fi
	kill -0 "$QPID" 2>/dev/null || break
	sleep 5
	_i=$((_i + 1))
done
kill "$QPID" 2>/dev/null || :
wait "$QPID" 2>/dev/null || :

say ''
step 'results'

if [ "$_done" != 1 ]; then
	no 'the guest did not report completion'
	say '  the last thing it said:'
	sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$WORK/guest.log" 2>/dev/null | tail -50
	KEEP=1
	say ''
	say "$PASS passed, $FAIL failed"
	exit 1
fi

# The guest counts its own checks and prints one line per check.  That report is
# what is read here; the host does not form its own opinion about the disk,
# because it cannot - only the guest had a chance to look at it.
#
# Read line by line from a file, not `for _line in $(grep ...)`: that form
# splits on whitespace and so yields one word per iteration, which turned the
# whole report into a single check called "ok" and a single failure called "no".
# tr -d '\r' because a serial console ends every line with CRLF.
grep -aE '^(ok|no) [0-9]+ ' "$WORK/guest.log" 2>/dev/null |
	tr -d '\r' >"$WORK/results.txt" || :
while IFS= read -r _line; do
	[ -n "$_line" ] || continue
	_k=${_line%% *}
	_rest=${_line#* }
	_rest=${_rest#* }
	case $_k in
	ok) ok "$_rest" ;;
	no) no "$_rest" ;;
	esac
done <"$WORK/results.txt"

# The guest's own tally has to agree with what was read out of the log.  If it
# does not, the log was cut short and some checks are being reported as neither a
# pass nor a fail, which would look like a clean run.
tr -d '\r' <"$WORK/guest.log" | sed -n 's/^summary passed=\([0-9]*\) failed=\([0-9]*\)$/pass=\1 fail=\2/p' |
	while IFS=' ' read -r _gp _gf; do
		[ -n "${_gp:-}" ] || continue
		if [ "${_gp#pass=}" != "$PASS" ] || [ "${_gf#fail=}" != "$FAIL" ]; then
			no "the host read $PASS/$FAIL from the log but the guest counted ${_gp#pass=}/${_gf#fail=}"
		fi
	done

say ''
say "  $(tr -d '\r' <"$WORK/guest.log" | grep -a '^passed: ' | tail -1)"

if [ "$VERBOSE" = 1 ]; then
	say ''
	say '--- the installer in the guest ---'
	sed -n '/--- running setup-disk ---/,/--- verifying ---/p' "$WORK/guest.log" 2>/dev/null |
		sed 's/\r$//' | head -70
fi

# --- does it boot? -----------------------------------------------------------

if [ "$BOOTCHECK" = 1 ]; then
	step 'booting from the installed disk, with nothing else attached'
	rm -f "$WORK/boot2.log" "$WORK/mon" "$WORK/text.bin"

	# The monitor socket is there for one reason: when the boot fails, the text
	# on the screen is the only thing that says why, and there is no display to
	# photograph.  It is read out of guest memory rather than off a screenshot
	# because 0xb8000 holds the characters themselves - a screenshot holds
	# pixels, which on a machine with no image input are not readable.
	timeout 420 qemu-system-x86_64 \
		-m 2048 \
		-drive "file=$DISK,format=raw,if=virtio,cache=writeback" \
		-boot c \
		-serial "file:$WORK/boot2.log" \
		-monitor "unix:$WORK/mon,server,nowait" \
		-display none -no-reboot >/dev/null 2>&1 &
	QPID=$!

	_n=0
	while [ ! -S "$WORK/mon" ] && [ "$_n" -lt 30 ]; do
		sleep 1
		_n=$((_n + 1))
	done

	# Long enough for Limine to load a 12 MB kernel and a 200 MB initramfs out
	# of ext4 and for the kernel to unpack it, with margin.
	sleep 240

	if [ -S "$WORK/mon" ]; then
		printf 'pmemsave 0xb8000 4000 %s\n' "$WORK/text.bin" |
			socat - "unix-connect:$WORK/mon" >/dev/null 2>&1 || :
		sleep 2
	fi
	kill "$QPID" 2>/dev/null
	wait "$QPID" 2>/dev/null

	# A boot is judged on Limine handing off to the kernel and the kernel
	# reaching userspace, not on the system being quiet afterwards: there is
	# no display, so X will fail, and a failing X is not a failed boot.
	if grep -qa 'Loading kernel' "$WORK/boot2.log" 2>/dev/null &&
	   grep -qa 'Loading module' "$WORK/boot2.log" 2>/dev/null &&
	   grep -qa 'FreeLinX 6\.' "$WORK/boot2.log" 2>/dev/null; then
		ok 'the installed system boots from its own disk'
	else
		no 'the installed system did not boot from its own disk'
		say ''
		say '--- the serial line ---'
		sed 's/\r$//' "$WORK/boot2.log" 2>/dev/null | tail -30
		if [ -s "$WORK/text.bin" ]; then
			say ''
			say '--- the screen ---'
			python3 - "$WORK/text.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
for r in range(25):
    row = d[r * 160:(r + 1) * 160]
    line = bytes(row[0::2]).decode('latin-1').rstrip()
    if line:
        print('  |%s' % line)
PY
		fi
	fi

	say ''
	say "$PASS passed, $FAIL failed"
fi

if [ "$FAIL" -ne 0 ]; then
	KEEP=1
	exit 1
fi
exit 0