#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# build-base.sh - build the two FreeLinX base images.
#
#   base               the installer image: kernel, initramfs, Limine, and
#                      the xsetup installer carried on the medium
#   base (boot only)   the same boot chain with no installer, which boots
#                      straight to a shell
#
# They differ in two ways, and both matter.
#
# The initramfs.  base boots the full rootfs, because base is a system you
# install from and the system you install has to be the one you were given.
# 'base (boot only)' boots a rescue set - shell, fileutils, vim, runit - from
# src/scripts/initramfs.sh, which builds both profiles from the one rootfs.
#
# The medium.  base carries the xsetup installer in /installer; the boot-only
# image does not, and boots straight to a shell.
#
# The ISO is composited with xorriso and then has Limine's BIOS stages written
# onto it by `limine bios-install`, which is the order Limine requires.
#
# xorriso is GPL.  It is a build-host tool and nothing it produces enters the
# image, so it does not affect the licensing of what ships.  ports/sysutils/
# flxiso is meant to replace it so the build host is non-GPU too; that port is
# not finished, and this script says so rather than pretending otherwise.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
# Sibling checkouts, per TestForBase/.gitmodules.
ROOT=$(cd "$HERE/.." && pwd)

SRC=$ROOT/src
ISO_REPO=$ROOT/iso
DRIVERS=$ROOT/drivers
LIMINE=$DRIVERS/bootloader/limine-binary

OUT_DIR=${OUT_DIR:-$HERE/out}
KERNEL=${KERNEL:-$SRC/rootfs/boot/vmlinuz}
INITRAMFS_SH=$SRC/scripts/initramfs.sh

# One initramfs per image, not one for both.
#
# src/scripts/initramfs.sh builds two profiles from one script, and they are not
# the same filesystem:
#
#   normal   the whole rootfs and a runit /init.  base.iso boots this, because
#            base.iso is a system you install from and it has to be the system
#            that gets installed - "a trimmed one would install a trimmed one".
#   rescue   shell, fileutils, vim, runit, terminfo, and an /init that says
#            plainly that it is a rescue environment.  'base (boot only).iso'
#            boots this.
#
# Until now this script read both images' initramfs out of iso/initramfs.img.gz,
# a binary checked into the iso repository on 30 September and never rebuilt.
# So neither image contained the current rootfs, the boot-only image was 31 MB of
# somebody else's idea of a system rather than the rescue set, and
#
#   FreeLinX: no init supervisor installed; starting rescue shell.
#
# - the message the shipped 31 MB archive's /init prints, a placeholder string
# that appears nowhere in this tree - was what booting the base image gave.  The
# build is here now so that cannot happen: an image is built from the rootfs in
# src/rootfs, or the build says why not.
INITRD=
INITRD_NORMAL=
INITRD_RESCUE=

C_RED=; C_GREEN=; C_BOLD=; C_OFF=
if [ -t 1 ]; then
	C_RED=$(printf '\033[31m'); C_GREEN=$(printf '\033[32m')
	C_BOLD=$(printf '\033[1m'); C_OFF=$(printf '\033[0m')
fi

die() { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '%s==> %s%s\n' "$C_BOLD" "$*" "$C_OFF"; }

need() {
	command -v "$1" >/dev/null 2>&1 ||
		die "missing tool: $1${2:+ ($2)}"
}

usage() {
	cat <<EOF
usage: ${0##*/} [-o OUTDIR] [-k KERNEL] [-i INITRD] [IMAGE]...

  IMAGE is base, bootonly, or both.  Default: both.
  -o DIR    where to write the images (default: $OUT_DIR)
  -k FILE   kernel image
  -i FILE   use this initramfs for both images instead of building one per
            profile.  For a test that injects its own archive; the shipped
            images are built from src/rootfs by src/scripts/initramfs.sh.

The two images do not boot the same initramfs.  base boots the full rootfs,
'base (boot only)' boots the rescue set; see src/scripts/initramfs.sh.
EOF
}

IMAGES=
while [ $# -gt 0 ]; do
	case $1 in
	-o) OUT_DIR=$2; shift ;;
	-k) KERNEL=$2; shift ;;
	-i) INITRD=$2; shift 2 ;;
	-h) usage; exit 0 ;;
	-*) die "unknown option: $1" ;;
	*)
		case $1 in
		base|bootonly|both)
			[ "$1" = both ] && IMAGES='bootonly base' || IMAGES="$IMAGES $1"
			;;
		*) die "not an image name: $1 (want base, bootonly, or both)" ;;
		esac
		;;
	esac
	shift
done

# No name given means the boot-only image: it is the one that can be built
# honestly right now, and base.iso needs the installer steps to exist.
[ -n "$IMAGES" ] || IMAGES=bootonly

need xorriso
need limine
need gzip
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
[ -f "$INITRAMFS_SH" ] ||
	die "no initramfs builder at $INITRAMFS_SH"

for f in limine-bios-cd.bin limine-uefi-cd.bin limine-bios.sys BOOTX64.EFI; do
	[ -f "$LIMINE/$f" ] || die "Limine file missing: $LIMINE/$f"
done

mkdir -p "$OUT_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# initramfs PROFILE - build one profile; sets INITRD_BUILT to its path.
#
# Sets a variable rather than printing the path, and the build function calls it
# as a statement rather than as $(initramfs profile).  A command substitution runs
# the body in a subshell, so every line of progress reporting goes into the
# captured value instead of to the terminal, and a failure inside it exits the
# subshell - which leaves the caller running with an empty argument and no
# reason to think anything went wrong.
initramfs() {
	_profile=$1
	[ -f "$INITRAMFS_SH" ] ||
		die "no initramfs builder at $INITRAMFS_SH"
	INITRD_BUILT=

	if [ -n "$INITRD" ]; then
		[ -f "$INITRD" ] || die "initramfs not found: $INITRD"
		gzip -t "$INITRD" 2>/dev/null || die "$INITRD is not a gzip archive"
		step "using the given initramfs for both images"
		say "  $INITRD ($(wc -c <"$INITRD" | tr -d ' ') bytes)"
		INITRD_BUILT=$INITRD
		return 0
	fi

	if [ "$_profile" = rescue ]; then
		INITRD_BUILT=$ISO_REPO/initramfs-rescue.img.gz
	else
		INITRD_BUILT=$ISO_REPO/initramfs-img.gz
	fi

	# Both profiles go through this, so a desktop that reached the rootfs cannot
	# reach either image.  Doing it here rather than as a step someone remembers
	# is the whole point: the desktop was in these images for as long as it was
	# in the tree, because nothing between the tree and the archive removed it.
	#
	# Nothing to suppress: the script is written to be safe to run twice, once
	# per profile.  A path that is already gone is skipped rather than being
	# an error, and the post-strip check is about var/service/xorg not being
	# there afterwards - which is true whether it was removed now or earlier.
	sh "$HERE/scripts/strip-desktop.sh" >"$WORK/strip-$_profile.log" 2>&1 || {
		sed 's/^/  | /' "$WORK/strip-$_profile.log" >&2
		die "the desktop strip failed; refusing to build an image that may still
     carry a desktop"
	}
	grep -a 'removed\|left\|zoneinfo' "$WORK/strip-$_profile.log" | sed 's/^/  /'

	step "building the $_profile initramfs"
	_report=$WORK/initramfs-$_profile.log
	if ! sh "$INITRAMFS_SH" -o "$INITRD_BUILT" "$_profile" >"$_report" 2>&1; then
		sed 's/^/  | /' "$_report" >&2
		die "the $_profile initramfs failed to build"
	fi
	grep -a 'entries\|output\|sha256' "$_report" | sed 's/^/  /'

	[ -s "$INITRD_BUILT" ] || die "the $_profile builder wrote no archive at $INITRD_BUILT"
	gzip -t "$INITRD_BUILT" 2>/dev/null ||
		die "$INITRD_BUILT does not pass gzip -t"
}

# lay_out STAGE INITRAMFS - put the boot chain into a staging directory.
lay_out() {
	_stage=$1
	_initrd=$2
	mkdir -p "$_stage/boot" "$_stage/EFI/BOOT"

	cp "$LIMINE/limine-bios-cd.bin" "$_stage/boot/"
	cp "$LIMINE/limine-uefi-cd.bin" "$_stage/boot/"
	cp "$LIMINE/limine-bios.sys"    "$_stage/boot/"
	cp "$LIMINE/BOOTX64.EFI" "$_stage/EFI/BOOT/"

	# Limine looks for the kernel and the initramfs by these names.
	cp "$KERNEL" "$_stage/boot/bzImage"
	cp "$_initrd" "$_stage/boot/initramfs.img.gz"

}

# compose STAGE OUT - xorriso, then Limine's BIOS stages.
compose() {
	_stage=$1
	_out=$2

	step "composing $_out"
	# -V FREELINX_MEDIUM: the volume id is how the booted system recognises the
	# medium it came from.  /init mounts a partition with this label at
	# /media/flx, read-only, and /usr/sbin/xsetup runs the installer from
	# there - so without it the installer is on the disc and unreachable from
	# the system booted off that disc, and the only way to run it is to know to
	# type "mount /dev/sr0 /mnt" first.
	#
	# Not "freelinx": that is the label xsetup.d/setup-disk.sh gives the
	# installed root filesystem (mkfs.ext4 -q -L freelinx), and the two would
	# then be told apart by letter case.  Upper case is what an iso9660 volume
	# id is stored as anyway.
	xorriso -as mkisofs -R -r -J \
		-V FREELINX_MEDIUM \
		-b boot/limine-bios-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		-hfsplus -apm-block-size 2048 \
		--efi-boot boot/limine-uefi-cd.bin \
		-efi-boot-part --efi-boot-image --protective-msdos-label \
		"$_stage" -o "$_out" >/dev/null 2>&1 ||
		die "xorriso failed for $_out"

	# Must come after xorriso: it rewrites the MBR and converts the GPT for
	# BIOS, so running it before would be undone.
	step "installing Limine BIOS stages"
	limine bios-install "$_out" >/dev/null 2>&1 ||
		die "limine bios-install failed for $_out"

}

# textmode: yes - hand the kernel a legacy text screen, not a framebuffer.
#
# This is the whole reason the graphical console works at all.  vgacon, the only
# console driver in this kernel (there is no CONFIG_FB, so there is no fbcon),
# refuses to bind when the bootloader reports a linear framebuffer instead of a
# text mode:
#
#     drivers/video/console/vgacon.c:155
#         if (screen_info.orig_video_isVGA == VIDEO_TYPE_VLFB ||
#             screen_info.orig_video_isVGA == VIDEO_TYPE_EFI) {
#           no_vga:
#             conswitchp = &dummy_con;
#             return conswitchp->con_startup();
#         }
#
# Limine reports VIDEO_TYPE_VLFB whenever it has a framebuffer to hand over,
# which is its default, so the kernel printed
#
#     Console: colour dummy device 80x25
#
# bound the dummy console, and /sys/class/vtconsole/vtcon0/name stayed
# "(S) dummy device".  Everything written to tty1 was discarded: the login shell
# on the virtual terminals existed, answered nothing visible, and a machine with
# no serial cable showed Limine's menu and then a black screen.  The serial line
# worked throughout, which is why this went unnoticed - the bug is invisible to
# exactly the test that was being run.
#
# When Limine is told textmode, it calls vga_textmode_init() and reports
# orig_video_mode 3 / orig_video_isVGA VIDEO_TYPE_VGAC, which is what vgacon
# needs.
#
# The key is "textmode", with no underscore, and that is not a typo.  Limine
# looks the key up as the literal string "TEXTMODE":
#
#     common/protos/linux_x86.c:691
#         char *textmode_str = config_get_value(config, 0, "TEXTMODE");
#
# and config_get_value matches the text of the key against the text of the
# argument with nothing in between to reconcile an underscore:
#
#     common/lib/config.c:762
#         if (!strncasecmp(&config[i], key, key_len) && config[i + key_len] == ':')
#
# so "text_mode:" does not match "TEXTMODE" - the fifth character is _ against
# M - and the setting is discarded with no warning at all.  The bootloader then
# hands over a framebuffer as if nothing had been asked for.  Limine's own
# config key list has the same spelling, "TEXTMODE" in common/menu.c, which is
# where the underscore-free form comes from.  Written the documented-looking way
# this line does nothing whatsoever.
#
# It also has to go INSIDE the menu entry, not above it, and that is the second
# mistake that was made here.  Limine reads it as
#
#     common/protos/linux_x86.c:691
#         char *textmode_str = config_get_value(config, 0, "TEXTMODE");
#
# where the config is the body of the entry being booted.  A key above the first "/"
# is global, and globals are read with a NULL config:
#
#     common/menu.c:55
#         char *layout = config_get_value(NULL, 0, "keyboard_layout");
#
# so a textmode line above /FreeLinX is never seen by the Linux handover at all.
# Limine does not complain about that either.  It hands over a framebuffer as if
# nothing had been asked for, vgacon refuses it, and the graphical console is dead
# while the serial line keeps working - invisible to any test that reads the
# serial line, which is the test that was being run.
#
# So the setting is written inside the entry below, and only there.
#
# The block reading this key is inside #if defined (BIOS), so on UEFI it is not
# compiled in at all and the same refusal happens: Limine reports VIDEO_TYPE_EFI.
# base is a shell image - no X client, no DRM driver, CONFIG_FB off - so a UEFI
# machine has no on-screen console.  The serial line and the installer work there.

# limine_conf STAGE TITLE CMDLINE - write the boot menu.
limine_conf() {
	_stage=$1
	_title=$2
	_cmdline=$3
	# The heredoc is unquoted so $_stage, $_title and $_cmdline expand, which
	# also means a backtick anywhere in what follows is a command to run.  That
	# is how a comment inside this heredoc once produced
	#
	#   build-base.sh: line 257: config: command not found
	#
	# out of a quoted C call in a prose comment about config_get_value.  The
	# explanation of the textmode key lives above the function for that reason
	# and not for tidiness.
	cat >"$_stage/limine.conf" <<EOF
timeout: 5
serial: yes

/$_title
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: $_cmdline
    textmode: yes
EOF
}

# build_bootonly - the image with no installer on it.
build_bootonly() {
	_out=$OUT_DIR/'base (boot only).iso'
	_stage=$WORK/bootonly

	step 'building base (boot only)'
	initramfs rescue
	lay_out "$_stage" "$INITRD_BUILT"
	limine_conf "$_stage" 'FreeLinX' \
		'rdinit=/init console=tty0 console=ttyS0,115200 quiet loglevel=2'
	compose "$_stage" "$_out"

	printf '%s  ok%s %s (%s bytes)\n' "$C_GREEN" "$C_OFF" "$_out" \
		"$(wc -c <"$_out" | tr -d ' ')"
	unset _out _stage
}

# build_base - the same, plus the installer on the medium.
build_base() {
	_out=$OUT_DIR/base.iso
	_stage=$WORK/base

	step 'building base'
	initramfs normal
	lay_out "$_stage" "$INITRD_BUILT"

	# The installer travels on the medium.  /installer is its own tree so
	# the payload is obvious on the disc and cannot collide with /boot.
	mkdir -p "$_stage/installer/lib" "$_stage/installer/xsetup.d"
	cp "$HERE/xsetup" "$_stage/installer/xsetup"
	cp "$HERE"/lib/*.sh "$_stage/installer/lib/"
	cp "$HERE"/xsetup.d/*.sh "$_stage/installer/xsetup.d/"
	if [ -d "$HERE/overlay" ]; then
		cp -R "$HERE/overlay/." "$_stage/installer/"
	fi
	chmod +x "$_stage/installer/xsetup"

	# A README on the medium, so the disc explains itself when booted.
	cat >"$_stage/README.TXT" <<EOF
FreeLinX base
=============

Boot menu
---------
  FreeLinX   boots the system on this medium.

Installer
---------
The installer is in /installer on this medium, and this medium is mounted at
/media/flx when the system booted from it comes up.  So the installer is one
command, from the prompt:

    xsetup

It needs root and a writable root filesystem, and it writes to the disk you
choose.  It asks its questions in order and records what it has done, so an
install that is interrupted can be resumed.

If /media/flx is not there - you booted from a USB stick, or you moved the disc
- mount this medium somewhere and run the installer from it directly:

    mount -t iso9660 /dev/sr0 /mnt
    sh /mnt/installer/xsetup

To install to RAM only, with nothing written to disk, boot the image and use
the shell you are given.  Nothing persists across a reboot.
EOF

	limine_conf "$_stage" 'FreeLinX' \
		'rdinit=/init console=tty0 console=ttyS0,115200 quiet loglevel=2'

	compose "$_stage" "$_out"

	printf '%s  ok%s %s (%s bytes)\n' "$C_GREEN" "$C_OFF" "$_out" \
		"$(wc -c <"$_out" | tr -d ' ')"
	unset _out _stage
}

printf '%s%s: building the FreeLinX base images%s\n' "$C_BOLD" "$C_GREEN" "$C_OFF"
printf '  kernel     %s (%s bytes)\n' "$KERNEL" "$(wc -c <"$KERNEL" | tr -d ' ')"
printf '  rootfs     %s\n' "$SRC/rootfs"
printf '  limine     %s\n' "$LIMINE"
printf '  output     %s\n' "$OUT_DIR"
printf '\n'

# The installer step files are only present once they are written; a base
# image with no steps would be a lie, so check before spending ten minutes on
# an ISO.  Only base.iso carries the installer, so only base.iso needs this.
case " $IMAGES " in
*' base '*)
	if [ ! -d "$HERE/xsetup.d" ] ||
	   [ -z "$(ls -A "$HERE/xsetup.d" 2>/dev/null)" ]; then
		die 'xsetup.d has no step files yet, so base.iso would have no
     installer.  Build the boot-only image instead, or finish the steps.'
	fi
	;;
esac

for _img in $IMAGES; do
	case $_img in
	bootonly) build_bootonly ;;
	base)     build_base ;;
	esac
done

say ''
say "done.  built:$IMAGES"
say 'each image boots on BIOS and on UEFI.'
