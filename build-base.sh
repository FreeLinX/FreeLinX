#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# build-base.sh - build the FreeLinX base ISO: the system, a shell, no desktop.
#
#   sh build-base.sh            -> out/freelinx-base-x86_64.iso
#
# Base is the desktop release's system with the desktop taken out
# (scripts/mkrootfs.sh), so it has the same kernel, the same userland and the
# same no-GNU gate.  It boots the same way the desktop ISO does: the whole
# system is the initramfs, unpacked into ramfs, and /init runs runit.
#
# Installing is `xsetup`: the desktop's flxinstall under base's name.  It is the one
# that matches /init's boot model (system image on the ESP, persistent
# /usr /etc /var /root on FLX_SYS, /home on FLX_HOME, partitions pinned by
# UUID) and the one `flxupgrade` upgrades.  On an image with no desktop it
# installs a console system without asking.
#
# The medium is labelled FREELINX_LIVE because flxupgrade finds it by that.
#
# Environment:
#   DESK       the FreeLinX-desk checkout        (default: ../Desktop-test)
#   KERNEL     the kernel image                  (default: $DESK/kernel/bzImage)
#   LIMINE_DIR Limine binaries                   (default: $DESK/iso/limine)
#   OUT        the ISO to write    (default: out/freelinx-base-x86_64.iso)
#   SERIAL=1   also put the console on ttyS0 (for tests)
#   FLX_HW_TARBALL       lib/firmware + lib/modules (default: $DESK/firmware-*.tar.xz)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DESK=${DESK:-$ROOT/Desktop-test}
KERNEL=${KERNEL:-$DESK/kernel/bzImage}
LIMINE_DIR=${LIMINE_DIR:-$DESK/iso/limine}
OUT=${OUT:-$HERE/out/freelinx-base-x86_64.iso}
VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo 1.0.7)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

for t in xorriso cpio xz; do
	command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
for f in limine limine-bios-cd.bin limine-uefi-cd.bin limine-bios.sys BOOTX64.EFI; do
	[ -f "$LIMINE_DIR/$f" ] || die "missing $LIMINE_DIR/$f"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/flxbase.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
STAGE=$WORK/rootfs
ISO=$WORK/iso

# --- the system ----------------------------------------------------------------
DESK=$DESK sh "$HERE/scripts/mkrootfs.sh" -o "$STAGE"

mkdir -p "$STAGE/boot"
cp -f "$KERNEL" "$STAGE/boot/vmlinuz"

# Hardware blobs: firmware, and the kernel's modules.
#
# Firmware is not in git - vendor blobs - and without it real WiFi, GPUs and
# audio codecs do not come up.  The linux-firmware package carries the common
# set; the tarball adds the rest when it is there.
#
# Modules come from the same tarball because they arrive the same way when they
# arrive at all.  The linux package carries them, and that package is built by
# the desktop stack, so a base built from this repository has no other source for
# them.  Which left the tree's own /lib/modules - 6.6.21 - sitting in the image
# beside a 6.6.157 kernel, where modprobe cannot load any of it.  So the
# directory is replaced rather than added to, and the kernel the image boots is
# the only version left in it.
HW=${FLX_HW_TARBALL:-${FLX_FIRMWARE_TARBALL:-}}
if [ -z "$HW" ]; then
	for c in "$DESK"/firmware-*.tar.xz; do [ -f "$c" ] && HW=$c && break; done
fi
if [ -n "$HW" ] && [ -f "$HW" ]; then
	step "hardware blobs from ${HW##*/}"
	tar -xf "$HW" -C "$STAGE" lib/firmware 2>/dev/null || :
	if [ -d "$STAGE/lib/modules" ]; then
		rm -rf "${STAGE:?}/lib/modules"
	fi
	tar -xf "$HW" -C "$STAGE" lib/modules 2>/dev/null || :
fi
# One kernel, one module directory.  The tree this image was built from carried
# 6.6.21 modules, and pairing those with a 6.6.157 kernel gives an image that
# boots with no loadable module at all - so a second version here is refused
# rather than shipped.  A tarball built for a different kernel is a packaging
# mistake and this is where it shows; the version is named because the number in
# the path is the only place it appears.
if [ -d "$STAGE/lib/modules" ]; then
	set -- "$STAGE"/lib/modules/*/
	if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
		die "lib/modules holds $# kernel versions; it must hold exactly one"
	fi
	kv=${1%/}; kv=${kv##*/}
	step "    modules for $kv"
fi

# Modes git cannot carry, as the desktop image build sets them.
chmod 0600 "$STAGE/etc/shadow"
chmod 0700 "$STAGE/root"
chmod 1777 "$STAGE/tmp"
[ -d "$STAGE/var/tmp" ] && chmod 1777 "$STAGE/var/tmp"
for b in usr/bin/doas usr/sbin/unix_chkpwd bin/su bin/newgrp; do
	[ -f "$STAGE/$b" ] && chmod 4755 "$STAGE/$b"
done
if [ -f "$STAGE/usr/sbin/unix_chkpwd" ] && [ ! -e "$STAGE/sbin/unix_chkpwd" ]; then
	ln -s ../usr/sbin/unix_chkpwd "$STAGE/sbin/unix_chkpwd"
fi
[ -f "$STAGE/etc/doas.conf" ] && chmod 0600 "$STAGE/etc/doas.conf"
find "$STAGE" -name .gitkeep -type f -exec rm -f {} +
printf '%s\n' "$VERSION" >"$STAGE/etc/flx-base-version"

# The version base is released as.  /init compares VERSION_ID with the one
# recorded on FLX_SYS to decide whether an installed system's files need
# refreshing, flxinstall names the boot entries after it, and /init rewrites
# the " FreeLinX x.y.z" banner line in that exact form.
cat >"$STAGE/etc/os-release" <<EOF
NAME=FreeLinX
ID=freelinx
VERSION="$VERSION (base)"
VERSION_ID="$VERSION"
VERSION_CODENAME=base
PRETTY_NAME="FreeLinX $VERSION base"
ANSI_COLOR="1;36"
BUILD_ID="$VERSION"
HOME_URL="https://github.com/FreeLinX"
SUPPORT_URL="https://github.com/FreeLinX"
BUG_REPORT_URL="https://github.com/FreeLinX/FreeLinX-base/issues"
EOF
# /etc/issue and /etc/motd are written here, not edited.  Both come from the
# desktop: a Plan 9 Rio banner whose version line reads
#
#      FreeLinX 1.0 (Rio Workstation Edition) - Static Musl / Linux 6.6
#
# so this used to sed " FreeLinX 1.0.x" and then die unless the result was
# exactly " FreeLinX $VERSION" - which it never was, and every build stopped
# here before it made an ISO.  mkrootfs.sh had a second attempt at the same two
# files, sed-ing a different line the desktop banner also lacks, and then
# refusing the file for containing the word "desktop", which it did in four
# other lines.
#
# Written out instead, and not trimmed afterwards, because both files are read:
# sshd shows /etc/issue before the password prompt and flxconsole writes
# /etc/motd to every console it opens, which on base is the only thing on screen
# between the boot log and the prompt.  Neither rewrites it, so this is the one
# place the version is stamped; nothing else will put it there later.
#
# The logo is artwork rather than text, and it is the widest and tallest thing
# on the screen and the only graphic on a machine with no desktop, so it is
# reproduced as it was given rather than tidied: trailing spaces and all.  Each
# backslash in it is written twice below and comes out once, because this
# heredoc is unquoted so that $VERSION expands in it.
for f in etc/motd etc/issue; do
	cat >"$STAGE/$f" <<EOF
 _____              _     _      __  __
|  ___| __ ___  ___| |   (_)_ __ \\ \\/ /
| |_ | '__/ _ \\/ _ \\ |   | | '_ \\ \\  / 
|  _|| | |  __/  __/ |___| | | | |/  \\ 
|_|  |_|  \\___|\\___|_____|_|_| |_/_/\\_\\

 FreeLinX $VERSION base

 Live system: nothing is kept until it is installed.

 Install to disk: xsetup (as root).  Manuals: man <command>.
 Packages: xpkg install <name>, xpkg list.
 Bugs: https://github.com/FreeLinX/FreeLinX/issues
EOF
	grep -q "^ FreeLinX $VERSION base\$" "$STAGE/$f" || die "wrote $f without its version line"
done

# The gate again, on what is actually packed (firmware included).
sh "$DESK/check-nognu.sh" "$STAGE" >"$WORK/nognu.txt" 2>&1 || {
	grep '^FAIL' "$WORK/nognu.txt" >&2
	die 'GNU artefacts in the image'
}
tail -1 "$WORK/nognu.txt"

# xz with CRC32 (what the kernel's decoder accepts).  Not zstd: Linux ignores a
# cpio appended after a zstd image, and flxinstall appends one.
step 'packing the initramfs'
mkdir -p "$ISO/boot/limine" "$ISO/EFI/BOOT"
(cd "$STAGE" && find . -print0 |
	cpio --null -o --quiet --format=newc --owner=0:0 |
	xz -T0 -6 --check=crc32) >"$ISO/boot/initramfs.img.gz"

# --- the medium ----------------------------------------------------------------
cp -f "$KERNEL" "$ISO/boot/bzImage"
cp -f "$LIMINE_DIR/limine-bios-cd.bin" "$LIMINE_DIR/limine-uefi-cd.bin" \
	"$LIMINE_DIR/limine-bios.sys" "$ISO/boot/limine/"
cp -f "$LIMINE_DIR/BOOTX64.EFI" "$ISO/EFI/BOOT/BOOTX64.EFI"

SERIAL_ARGS=; SERIAL_CONF=
if [ "${SERIAL:-0}" = 1 ]; then
	SERIAL_ARGS='console=ttyS0,115200'
	SERIAL_CONF='serial: yes'
fi
# rootfstype=ramfs: the unpacked system is bigger than tmpfs' default cap of
# half the RAM on a 2 GB machine.
#
# console=tty0 is last, so /dev/console is the screen and not the serial line.
# Every console= on the line gets the kernel's output either way; what the last
# one decides is where /init and everything it starts write.  That is the
# terminal the operator is answering the installer's questions on, and a serial
# line that may not be plugged in is the wrong place for it.
#
# No quiet and no loglevel=.  Both said the same thing - show almost nothing -
# and together they left a successful boot printing nothing at all until the
# login prompt, so the screen went from the bootloader to a prompt with nothing
# in between.  A person installing FreeLinX to a machine they cannot see into
# gets to watch it boot.
cat >"$ISO/boot/limine/limine.conf" <<EOF
timeout: 5
$SERIAL_CONF
# textmode: Limine hands over a text screen on BIOS instead of a framebuffer.
# vgacon needs a text screen and fbcon needs a framebuffer, so with this the
# console exists on BIOS whether or not a KMS driver turns up.  It has no effect
# on UEFI, where there is no text mode to hand over.
textmode: yes
interface_branding: FreeLinX $VERSION base

/FreeLinX $VERSION base (installer: xsetup)
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init rootfstype=ramfs $SERIAL_ARGS console=tty0

/Rescue shell
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init rootfstype=ramfs $SERIAL_ARGS console=tty0 flx.rescue=1
EOF

step "composing ${OUT##*/}"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
xorriso -as mkisofs -quiet -R -r -J -V FREELINX_LIVE \
	-b boot/limine/limine-bios-cd.bin -no-emul-boot -boot-load-size 4 \
	-boot-info-table -hfsplus -apm-block-size 2048 \
	--efi-boot boot/limine/limine-uefi-cd.bin -efi-boot-part --efi-boot-image \
	--protective-msdos-label "$ISO" -o "$OUT"
"$LIMINE_DIR/limine" bios-install "$OUT" >/dev/null 2>&1
(cd "$(dirname "$OUT")" && sha256sum "${OUT##*/}" >"${OUT##*/}.sha256")
step "done: $OUT ($(du -h "$OUT" | cut -f1))"
