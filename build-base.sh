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
# same no-GNU gate.  The system is a squashfs on the medium; a small initramfs
# (scripts/flxlive.c) mounts it with a tmpfs overlay and starts its /init.
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
#   BASE_FROM_DESKTOP=1  build from a built Desktop-test (scripts/mkrootfs.sh)
#   DESK       the FreeLinX-desk checkout        (default: ../Desktop-test)
#   KERNEL     the kernel image  (default: the linux package's
#              /usr/lib/linux/bzImage-*, so it matches /lib/modules; with
#              BASE_FROM_DESKTOP=1, $DESK/kernel/bzImage)
#   LIMINE_DIR Limine binaries   (default: ../drivers/bootloader/limine-binary,
#              else $DESK/iso/limine, else /usr/share/limine)
#   OUT        the ISO to write    (default: out/freelinx-base-x86_64.iso)
#   SERIAL=1   also put the console on ttyS0 (for tests)
#   FLX_HW_TARBALL       lib/firmware + lib/modules (default: $DESK/firmware-*.tar.xz)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DESK=${DESK:-$ROOT/Desktop-test}
[ "${BASE_FROM_DESKTOP:-0}" = 1 ] && KERNEL=${KERNEL:-$DESK/kernel/bzImage}
if [ -z "${LIMINE_DIR:-}" ]; then
	# Where Limine lives, in the order that finds it soonest.  The desktop
	# tree's copy only exists when BASE_FROM_DESKTOP is used; /usr/share/limine
	# only when a distribution package put it there.  This project's own copy is
	# in drivers, which every build of these repositories already has checked
	# out, so it is searched too: a build that needs an environment variable to
	# find a file that is in the tree next to it is a build that only works on
	# the machine it was written on.
	for c in "$ROOT/drivers/bootloader/limine-binary" "$DESK/iso/limine" /usr/share/limine; do
		if [ -f "$c/limine-bios-cd.bin" ]; then
			LIMINE_DIR=$c
			break
		fi
	done
	LIMINE_DIR=${LIMINE_DIR:-/usr/share/limine}
fi
OUT=${OUT:-$HERE/out/freelinx-base-x86_64.iso}
VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo 1.0.7)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }
say() { printf '%s\n' "$*"; }

for t in xorriso cpio xz; do
	command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
[ -z "${KERNEL:-}" ] || [ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
# the limine tool: next to its files (the desk tree), or installed (/usr/bin)
LIMINE=$LIMINE_DIR/limine
[ -x "$LIMINE" ] || LIMINE=$(command -v limine 2>/dev/null) ||
	die "no limine tool in $LIMINE_DIR or on PATH (limine bios-install writes the BIOS boot sector)"
for f in limine-bios-cd.bin limine-uefi-cd.bin limine-bios.sys BOOTX64.EFI; do
	[ -f "$LIMINE_DIR/$f" ] || die "missing $LIMINE_DIR/$f (searched $ROOT/drivers/bootloader/limine-binary, $DESK/iso/limine, /usr/share/limine)"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/flxbase.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
STAGE=$WORK/rootfs
ISO=$WORK/iso

# --- the system ----------------------------------------------------------------
DESK=$DESK sh "$HERE/scripts/mkrootfs.sh" -o "$STAGE"

# The kernel the linux package installed, so it is the one /lib/modules is for.
if [ -z "${KERNEL:-}" ]; then
	for k in "$STAGE"/usr/lib/linux/bzImage-*; do [ -f "$k" ] && KERNEL=$k; done
	[ -n "${KERNEL:-}" ] || die 'no kernel: the linux package has no /usr/lib/linux/bzImage-*'
fi

mkdir -p "$STAGE/boot"
# The linux package's kernel is already in the image: link to it rather than
# carry a second 16 MB copy.  setup-disk copies /boot/vmlinuz to the disk, and
# cp follows the link.
case $KERNEL in
"$STAGE"/*) ln -sf "../${KERNEL#"$STAGE"/}" "$STAGE/boot/vmlinuz" ;;
*) cp -f "$KERNEL" "$STAGE/boot/vmlinuz" ;;
esac

# Hardware blobs: firmware, and the kernel's modules.
#
# Firmware is not in git - vendor blobs - and without it real WiFi, GPUs and
# audio codecs do not come up.  The linux-firmware package carries the common
# set, so a build needs nothing else.  FLX_HW_TARBALL adds a newer set than the
# package has; the src repository publishes one as a release asset
# (github.com/FreeLinX/src/releases).  Nothing here fetches it, because 400 MB
# of vendor blobs downloaded unasked is not a decision a build script should
# make on its own.
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
	# Only a tarball that has modules replaces them.  firmware-<kver>.tar.xz
	# from build-firmware.sh has none, and emptying lib/modules for it left an
	# image whose kernel could load nothing.
	if tar -tf "$HW" 2>/dev/null | grep -q '^\(\./\)\{0,1\}lib/modules/.'; then
		rm -rf "${STAGE:?}/lib/modules"
		tar -xf "$HW" -C "$STAGE" lib/modules
	fi
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

# Firmware, said out loud.  The linux-firmware package is where the blobs come
# from; FLX_HW_TARBALL is for a newer set than the package carries, and the
# src release publishes one.  Nothing above here can tell the difference between
# an image whose WiFi, GPU and audio codecs work and one where every one of
# them loads its module and then sits there with the radio off, so the count is
# printed, and an image with none is refused rather than shipped: it is the one
# failure a person only finds out about when they plug the machine in.
if [ ! -d "$STAGE/lib/firmware" ]; then
	die 'no /lib/firmware: the linux-firmware package is in KEEP and installs it'
fi
set -- $(find "$STAGE/lib/firmware" -type f | wc -l)
[ "$1" -gt 0 ] || die "/lib/firmware is empty: no device can initialise without its blob"
step "    $1 firmware blobs"

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
# /etc/issue and /etc/motd are written here, not edited.  Both are plain
# text, the way real systems keep them (Debian's /etc/issue is one line,
# not a picture): a version line, a blank line, then what the session is
# and what to type.  No ASCII art - it drew differently on every console
# and read as decoration on the only screen a machine with no desktop has.
# sshd shows /etc/issue before the password prompt and flxconsole writes
# /etc/motd to every console it opens, which on base is the only thing on screen
# between the boot log and the prompt.  Neither rewrites it, so this is the one
# place the version is stamped; nothing else will put it there later.
for f in etc/motd etc/issue; do
	cat >"$STAGE/$f" <<EOF
 FreeLinX $VERSION base

 Live system: nothing is kept until it is installed.

 Install to disk: xsetup (as root).  Manuals: man <command>.
 Packages: xpkg install <name>, xpkg list.
 Bugs: https://github.com/FreeLinX/FreeLinX/issues
EOF
	grep -q "^ FreeLinX $VERSION base\$" "$STAGE/$f" || die "wrote $f without its version line"
done

# The gate again, on what is actually packed (firmware included).
sh "$HERE/scripts/check-nognu.sh" "$STAGE" >"$WORK/nognu.txt" 2>&1 || {
	grep '^FAIL' "$WORK/nognu.txt" >&2
	die 'GNU artefacts in the image'
}
tail -1 "$WORK/nognu.txt"

# xz with CRC32 (what the kernel's decoder accepts).  Not zstd: Linux ignores a
# cpio appended after a zstd image, and flxinstall appends one.
# --- the live medium's system --------------------------------------------------
# The live system is not unpacked into RAM.  It goes on the medium as one
# squashfs (zstd: the compressor this kernel has), and a small initramfs -
# flxlive as /init and a static sh for when it cannot go on - mounts it
# read-only with a tmpfs over it (overlayfs) and starts the system's /init.
# RAM then holds the session's changes and the page cache, as on other live
# media, instead of the whole system.
command -v mksquashfs >/dev/null 2>&1 || die 'missing tool: mksquashfs (squashfs-tools)'
step 'packing the system (squashfs)'
mkdir -p "$ISO/boot/limine" "$ISO/EFI/BOOT"
mksquashfs "$STAGE" "$ISO/boot/root.sfs" -comp zstd -Xcompression-level 19 -b 1M \
	-all-root -noappend -quiet >/dev/null || die 'mksquashfs failed'

step 'building the live initramfs'
# flxlive is built here with the musl toolchain: LIVECC, or the desk's flx-cc,
# or clang against the musl sysroot.
if [ -z "${LIVECC:-}" ]; then
	TC=$ROOT/toolchain
	if [ -x "$DESK/stack/work/bin/flx-cc" ]; then
		LIVECC=$DESK/stack/work/bin/flx-cc
	elif [ -x "$TC/bin/clang" ] && [ -f "$TC/x86_64-linux-musl/lib/libc.a" ]; then
		# ../toolchain: the FreeLinX toolchain release (toolchain.tar.gz)
		LIVECC="$TC/bin/clang --target=x86_64-linux-musl --sysroot=$TC/x86_64-linux-musl -fuse-ld=lld -rtlib=compiler-rt -unwindlib=none"
	else
		for sr in "${SYSROOT:-}" "$DESK/stack/work/sysroot" "$HOME/freelinix/toolchain/x86_64-linux-musl" \
			"$HOME/freelinx/toolchain/x86_64-linux-musl"; do
			[ -n "$sr" ] && [ -d "$sr" ] && break
			sr=
		done
		[ -n "$sr" ] && command -v clang >/dev/null 2>&1 ||
			die 'no musl C compiler for flxlive: set LIVECC, or SYSROOT with clang on PATH'
		LIVECC="clang --target=x86_64-linux-musl --sysroot=$sr -fuse-ld=lld -rtlib=compiler-rt -unwindlib=none"
	fi
fi
IRD=$WORK/initrd
mkdir -p "$IRD/bin" "$IRD/proc" "$IRD/sys" "$IRD/dev" "$IRD/run" "$IRD/newroot"
# shellcheck disable=SC2086  # LIVECC may be a command with arguments
$LIVECC -O2 -static -o "$IRD/init" "$HERE/scripts/flxlive.c" || die 'building flxlive failed'
cp "$STAGE/bin/sh" "$IRD/bin/sh"
sh "$HERE/scripts/check-nognu.sh" "$IRD" >/dev/null || die 'the live initramfs has GNU code in it'
(cd "$IRD" && find . -print0 |
	cpio --null -o --quiet --format=newc --owner=0:0 |
	xz -T0 -6 --check=crc32) >"$ISO/boot/initramfs.img.gz"
say "    system $(du -h "$ISO/boot/root.sfs" | cut -f1), initramfs $(du -h "$ISO/boot/initramfs.img.gz" | cut -f1)"

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
    cmdline: rdinit=/init $SERIAL_ARGS console=tty0

/Rescue shell
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init $SERIAL_ARGS console=tty0 flx.rescue=1
EOF

step "composing ${OUT##*/}"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
xorriso -as mkisofs -quiet -R -r -J -V FREELINX_LIVE \
	-b boot/limine/limine-bios-cd.bin -no-emul-boot -boot-load-size 4 \
	-boot-info-table -hfsplus -apm-block-size 2048 \
	--efi-boot boot/limine/limine-uefi-cd.bin -efi-boot-part --efi-boot-image \
	--protective-msdos-label "$ISO" -o "$OUT"
"$LIMINE" bios-install "$OUT" >/dev/null 2>&1
(cd "$(dirname "$OUT")" && sha256sum "${OUT##*/}" >"${OUT##*/}.sha256")
step "done: $OUT ($(du -h "$OUT" | cut -f1))"
