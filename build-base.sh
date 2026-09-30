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
# The difference between them is what is on the medium, not how it is built.
# Both boot the same kernel and the same initramfs; the boot-only image simply
# does not carry xsetup.
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
INITRD=${INITRD:-$ISO_REPO/initramfs.img.gz}

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
  -i FILE   initramfs image
EOF
}

IMAGES=
while [ $# -gt 0 ]; do
	case $1 in
	-o) OUT_DIR=$2; shift ;;
	-k) KERNEL=$2; shift ;;
	-i) INITRD=$2; shift ;;
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
[ -f "$INITRD" ] || die "initramfs not found: $INITRD"
gzip -t "$INITRD" 2>/dev/null || die "$INITRD is not a gzip archive"

for f in limine-bios-cd.bin limine-uefi-cd.bin limine-bios.sys BOOTX64.EFI; do
	[ -f "$LIMINE/$f" ] || die "Limine file missing: $LIMINE/$f"
done

mkdir -p "$OUT_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# lay_out STAGE - put the boot chain into a staging directory.
lay_out() {
	_stage=$1
	mkdir -p "$_stage/boot" "$_stage/EFI/BOOT"

	cp "$LIMINE/limine-bios-cd.bin" "$_stage/boot/"
	cp "$LIMINE/limine-uefi-cd.bin" "$_stage/boot/"
	cp "$LIMINE/limine-bios.sys"    "$_stage/boot/"
	cp "$LIMINE/BOOTX64.EFI" "$_stage/EFI/BOOT/"

	# Limine looks for the kernel and the initramfs by these names.
	cp "$KERNEL" "$_stage/boot/bzImage"
	cp "$INITRD" "$_stage/boot/initramfs.img.gz"

}

# compose STAGE OUT - xorriso, then Limine's BIOS stages.
compose() {
	_stage=$1
	_out=$2

	step "composing $_out"
	xorriso -as mkisofs -R -r -J \
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

# limine_conf STAGE TITLE CMDLINE - write the boot menu.
limine_conf() {
	_stage=$1
	_title=$2
	_cmdline=$3
	cat >"$_stage/limine.conf" <<EOF
timeout: 5
serial: yes

/$_title
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: $_cmdline
EOF
}

# build_bootonly - the image with no installer on it.
build_bootonly() {
	_out=$OUT_DIR/'base (boot only).iso'
	_stage=$WORK/bootonly

	step 'building base (boot only)'
	lay_out "$_stage"
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
	lay_out "$_stage"

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
The installer is in /installer on this medium.  It needs root and a writable
root filesystem, and it writes to the disk you choose, so run it from a
system that is already up:

    mount /dev/cdrom /mnt      # or wherever the medium is
    sh /mnt/installer/xsetup

It asks twelve questions, in order, and records what it has done, so an
install that is interrupted can be resumed.

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
printf '  initramfs  %s (%s bytes)\n' "$INITRD" "$(wc -c <"$INITRD" | tr -d ' ')"
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
