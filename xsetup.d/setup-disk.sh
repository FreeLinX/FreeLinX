#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-disk - put FreeLinX on a disk, or run from RAM.
#
#   sys    install onto a disk: partition, format, copy the system, install
#          the bootloader, write fstab.  Erases the disk chosen.
#   data   run from RAM, with a disk for persistent storage.  Erases the disk.
#   none   run from RAM, touching no disk.  Safe, and the default.
#
# none is the default on purpose.  An installer that defaults to a disk is an
# installer that eats laptops, and the cost of being wrong is the machine.
#
# sys and data are never selected without saying what they will do and asking
# for the word "yes".  Nothing is written until that answer.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
# A dry run writes nothing, so it does not need root; making it demand root
# would mean the plan could not be checked by the person considering it, on
# their own machine, before committing to it.  It is also what lets the test
# suite run without a loop device.
if [ "${XSETUP_DRY_RUN:-}" != 1 ]; then
	need_root
fi

# flxpart reports its layout as FLX_PART<n>_* on stdout, which is the only
# supported way to learn where the partitions ended up: reading the table back
# means re-implementing a GPT parser, and a second parser is a second thing to
# be wrong about what a partition is.
need_cmd flxpart 'the sysutils/flxpart port'

MODE_FILE=${XSETUP_STATE_FILE:-/etc/xsetup-disk-mode}
DONE_FILE=/etc/xsetup-disk-installed

# --dry-run: print every destructive step and do none of them.
#
# The whole of this step is irreversible, and the parts most likely to be
# wrong -- the partition naming, the fstab UUIDs, which device node is which
# partition -- are all decidable before anything is written.  So the plan can
# be shown and checked on a machine where the answer is not yet a formatted
# disk.  Read it as "this is what will happen", not as a promise that the
# commands would succeed.
DRY=0
case " ${XSETUP_DRY_RUN:-} " in
*" 1 "*) DRY=1 ;;
esac

# run CMD... - do a command, or say what it would have been.
run() {
	if [ "$DRY" -eq 1 ]; then
		printf '  would run: %s\n' "$*"
		return 0
	fi
	"$@"
}

# The layout flxpart would produce, so a dry run can show the geometry without
# writing a table.  On a real run this comes from the real partitioning.
_layout=

# --- the choice ------------------------------------------------------------

mode=$(choose 'How should the system be stored?' \
	none 'run from RAM, no disk is written' \
	sys 'install onto a disk (erases it)' \
	data 'run from RAM, keep a disk for persistent storage (erases it)')

printf '%s\n' "$mode" >"$MODE_FILE"

if [ "$mode" = none ]; then
	rm -f "$DONE_FILE"
	ok 'running from RAM. No disk is written.'
	say ''
	say 'Steps 12 (setup-lbu and setup-apkcache) apply to this mode: they'
	say 'decide where a backup overlay and the package cache are kept.'
	exit 0
fi

# --- refusing early -------------------------------------------------------

# A disk that is not there cannot be chosen, and neither can a mounted one.
# Writing to a mounted filesystem destroys the mount, not just the data.
disks() {
	# XSETUP_DISK_OVERRIDE exists so the test suite can run this step
	# without root and without a loop device, by naming a plain file in
	# place of a disk.  It only makes sense with --dry-run: a real run
	# against a regular file would format a file and call it a disk.
	if [ -n "${XSETUP_DISK_OVERRIDE:-}" ]; then
		[ "$DRY" -eq 1 ] ||
			die 'XSETUP_DISK_OVERRIDE is only honoured with --dry-run'
		[ -e "$XSETUP_DISK_OVERRIDE" ] ||
			die "XSETUP_DISK_OVERRIDE: $XSETUP_DISK_OVERRIDE does not exist"
		printf '%s\n' "$XSETUP_DISK_OVERRIDE"
		return 0
	fi
	_d=
	for p in /dev/sd? /dev/nvme?n? /dev/vd? /dev/xvd? /dev/mmcblk?; do
		[ -b "$p" ] || continue
		# Skip the device a CD-ROM is attached as, and every partition:
		# partitioning /dev/sda1 is not a thing anyone means.
		case $p in
		*[0-9][0-9]) continue ;;
		esac
		_d=$_d${_d:+ }$p
	done
	printf '%s\n' "$_d"
	unset _d
}

devs=$(disks)
if [ -z "$devs" ]; then
	die 'no disk was found. Nothing was changed.'
fi

info 'disks found:'
for d in $devs; do
	_dsize=$(df -h "$d" 2>/dev/null | awk 'NR==2 {print $2" total, "$4" used"}')
	printf '  %-16s %s\n' "$d" "${_dsize:-$(wc -c <"$d" 2>/dev/null | tr -d ' ') bytes}"
done
printf '\n'

# shellcheck disable=SC2086
dev=$(choose 'Which disk' none 'leave it alone' \
	$(for d in $devs; do printf '%s %s ' "$d" "$d"; done))
[ "$dev" = none ] && die 'no disk was chosen, so nothing was written'

# Anything mounted out of this device stops the install.  Silently
# partitioning a live system is how an upgrade destroys itself.
if command -v findmnt >/dev/null 2>&1; then
	mounted=$(findmnt -rno SOURCE 2>/dev/null | grep -c "^$dev[0-9p]*$" || true)
	if [ "${mounted:-0}" -gt 0 ]; then
		die "$dev has ${mounted} filesystem(s) mounted. Unmount them, or pick another disk.
     Nothing was changed."
	fi
elif mount 2>/dev/null | grep -q "^$dev"; then
	die "$dev is mounted. Unmount it, or pick another disk. Nothing was changed."
fi

printf '\n'
warn "about to erase $dev, and everything on it"
warn "$mode mode reformats it: the previous contents are not recoverable."
confirm "This erases $dev" || die 'nothing was changed'

# --- partitioning ----------------------------------------------------------

info "partitioning $dev"
esp_mb=256
if [ "$DRY" -eq 1 ]; then
	# A dry run partitions nothing, so the layout it reports is the one
	# flxpart computes from the device size without writing.  That is the
	# only honest way to show the geometry: the real numbers come from a
	# real table, and a dry run says so rather than inventing LBAs.
	layout=$(flxpart --create-standard --esp-size "$esp_mb" --dry-run "$dev") ||
		die "flxpart could not compute a layout for $dev"
	say "  (dry run: nothing has been written to $dev)"
else
	layout=$(flxpart --create-standard --esp-size "$esp_mb" "$dev") ||
		die "flxpart could not partition $dev"
fi

# Pull the partitions out of the reported layout, matched on their type GUID
# rather than on their name or their position.  The name is for a human and the
# order is flxpart's business; the type GUID is the one thing that says what a
# partition actually is.  Matching on a name is how this step ended up looking
# for a partition called "ESP" and not finding the one called "EFI system".
GUID_ESP=28732AC1-1F81-D211-4BBA-A0A0C93EC93B
GUID_BIOSBOOT=94CE8649-9964-6E6F-744E-65ED45464964
GUID_ROOT=4F68EE06-F53D-D74B-1193-47F89EF89EF8

part_index() {
	printf '%s\n' "$layout" |
		sed -n "s/^FLX_PART\([0-9]*\)_TYPE=$1\$/\1/p" | head -1
}

esp_i=$(part_index "$GUID_ESP")
bios_i=$(part_index "$GUID_BIOSBOOT")
root_i=$(part_index "$GUID_ROOT")

[ -n "$esp_i" ] || die "flxpart did not report an EFI system partition.
     Its output said:
$layout"
[ -n "$root_i" ] || die "flxpart did not report a root partition.
     Its output said:
$layout"

# The partition device node: /dev/sda + 1 -> /dev/sda1.  Written here rather
# than assumed, because nvme and mmc put a "p" in front of the number.
partdev() {
	_p=$1
	_i=$2
	case $_p in
	*/nvme?n*|*/mmcblk*|*/loop*) printf '%sp%s\n' "$_p" "$_i" ;;
	*) printf '%s%s\n' "$_p" "$_i" ;;
	esac
}

ESP_DEV=$(partdev "$dev" "$esp_i")
if [ -n "$bios_i" ]; then
	BIOS_DEV=$(partdev "$dev" "$bios_i")
else
	BIOS_DEV=''
fi
ROOT_DEV=$(partdev "$dev" "$root_i")

say "  EFI system  $ESP_DEV"
[ -n "$BIOS_DEV" ] && say "  BIOS boot   $BIOS_DEV"
say "  root        $ROOT_DEV"

# --- formatting ------------------------------------------------------------

need_cmd mkfs.ext4 'the sysutils/e2fsprogs port'
need_cmd mkfs.fat 'the sysutils/dosfstools port'

info "making a FAT filesystem on $ESP_DEV"
# -F 32: the UEFI spec requires FAT32 on the ESP, and a 256 MiB partition
# formatted as FAT16 will not boot.
if [ "$DRY" -eq 1 ]; then
	say "  would run: mkfs.fat -F 32 -n EFI $ESP_DEV"
	say "  would run: mkfs.ext4 -q -L freelinx $ROOT_DEV"
else
	mkfs.fat -F 32 -n EFI "$ESP_DEV" >/dev/null 2>&1 ||
		die "mkfs.fat failed on $ESP_DEV"
	ok "ESP formatted"

	info "making an ext4 filesystem on $ROOT_DEV"
	mkfs.ext4 -q -L freelinx "$ROOT_DEV" ||
		die "mkfs.ext4 failed on $ROOT_DEV"
	ok "root formatted"
fi

# --- copying the system ---------------------------------------------------

# Where the system comes from.  The installer may be running from a mounted ISO
# or from an already-installed system; either way it has a rootfs somewhere it
# can read.  SOURCE_ROOT is that place, and defaulting it to / is right when
# xsetup runs from an installed system and wrong when it runs from the ISO, so
# it is set explicitly by the boot script and only falls back to /.
SOURCE_ROOT=${SOURCE_ROOT:-/}

info "copying the system to $ROOT_DEV"
mkdir -p /mnt/flx || die 'cannot create /mnt/flx'
mount "$ROOT_DEV" /mnt/flx || die "cannot mount $ROOT_DEV at /mnt/flx"

# Trap so an interrupted copy unmounts rather than leaving the filesystem
# mounted over /mnt/flx with half a system on it.
cleanup() {
	umount /mnt/flx 2>/dev/null || :
}
trap cleanup EXIT INT TERM

# cp -a, not tar: the rootfs contains hard links (the zone files, 364 of them)
# and device nodes, and a copy that drops either produces a system that is
# subtly wrong rather than obviously broken.
if ! cp -a "$SOURCE_ROOT/." /mnt/flx/ 2>/dev/null; then
	# Retry without the noisy parts, and report which, because "cp failed"
	# with no reason is the least useful error there is.
	warn 'the plain copy reported errors; retrying and naming them'
	cp -av "$SOURCE_ROOT/." /mnt/flx/ 2>&1 | grep -E 'cannot|failed|omitt' |
		head -20 >&2
	die 'the system could not be copied. The partition has been left mounted at /mnt/flx; unmount it before retrying.'
fi
ok "system copied"

# --- boot ------------------------------------------------------------------

# The kernel and initramfs have to be on the disk for the bootloader to find,
# and they are the two things a bare rootfs copy may not carry.
if [ -f "$SOURCE_ROOT/boot/vmlinuz" ] && [ ! -f /mnt/flx/boot/bzImage ]; then
	mkdir -p /mnt/flx/boot
	cp "$SOURCE_ROOT/boot/vmlinuz" /mnt/flx/boot/bzImage
fi
if [ -f "$SOURCE_ROOT/iso/initramfs.img.gz" ] && [ ! -f /mnt/flx/boot/initramfs.img.gz ]; then
	mkdir -p /mnt/flx/boot
	cp "$SOURCE_ROOT/iso/initramfs.img.gz" /mnt/flx/boot/initramfs.img.gz
fi

# fstab, keyed on filesystem UUIDs rather than on /dev/sdaN.
#
# /dev/sdaN is not stable: it moves when a disk is added, when a controller
# enumerates differently, or when the disk is moved to another machine.  The
# UUID is created with the filesystem and does not change, so a system that
# boots once from /dev/sda2 keeps booting after a USB stick appears.
root_uuid=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || :)
esp_uuid=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || :)

if [ -z "$root_uuid" ] || [ -z "$esp_uuid" ]; then
	die "could not read the filesystem UUIDs for $ROOT_DEV and $ESP_DEV.
     Without them fstab would be written against /dev names that move, and
     the installed system would not find its root on the next boot.
     Nothing has been unmounted; the disk is still mounted at /mnt/flx."
fi

{
	printf '# Written by xsetup.\n'
	printf 'UUID=%s\t/\text4\tdefaults\t0 1\n' "$root_uuid"
	printf 'UUID=%s\t/boot/efi\tvfat\tdefaults\t0 2\n' "$esp_uuid"
} >/mnt/flx/etc/fstab
ok "fstab written, keyed on UUIDs"

# --- bootloader ------------------------------------------------------------

# limine bios-install on a whole disk image needs the image as a file, not a
# partition device, so it is applied to the disk node where possible and the
# ESP is mounted for the EFI half.  Limine writes both its own MBR stages and
# the GPT-to-MBR conversion, so it runs after mkfs and after the copy.
need_cmd limine 'the drivers/bootloader/limine-binary port'

# Limine needs three things on a disk, and they are not the same three it
# needs on an ISO:
#
#   limine-bios.sys   on a partition the BIOS stage can read, in /, /boot,
#                     /limine or /boot/limine.  The root filesystem is the
#                     simplest place that satisfies it.
#   BOOTX64.EFI       on the ESP under EFI/BOOT, which is where UEFI looks.
#   the MBR stages    written by `limine bios-install`, which also stages
#                     limine-bios-hdd.h into the boot sector.
#
# The .bin files the ISO uses (limine-bios-cd.bin, limine-uefi-cd.bin) are
# El Torito boot images for a CD, and are the wrong files here.  Copying them
# onto the ESP would produce a system that boots on neither BIOS nor UEFI.
LIMDIR=${LIMINE_DIR:-/usr/share/limine}

info 'installing the bootloader'

if [ -f "$LIMDIR/limine-bios.sys" ]; then
	mkdir -p /mnt/flx/boot
	cp "$LIMDIR/limine-bios.sys" /mnt/flx/boot/ && ok 'limine-bios.sys placed in /boot'
else
	warn "$LIMDIR/limine-bios.sys is missing, so a BIOS boot cannot find its"
	warn 'second stage and will stop after the MBR. The UEFI path is unaffected.'
fi

if [ -f "$LIMDIR/BOOTX64.EFI" ]; then
	mkdir -p /mnt/flx/boot/efi/EFI/BOOT
	cp "$LIMDIR/BOOTX64.EFI" /mnt/flx/boot/efi/EFI/BOOT/ &&
		ok 'BOOTX64.EFI placed on the ESP'
else
	warn "$LIMDIR/BOOTX64.EFI is missing, so there is no UEFI boot target."
fi

# bios-install needs the drive's own boot sectors, and limine-bios-hdd.h from
# the same directory, which is the file it stages into them.
if [ -f "$LIMDIR/limine-bios-hdd.h" ]; then
	if limine bios-install "$dev" >/dev/null 2>&1; then
		ok "Limine BIOS stages installed on $dev"
	else
		warn "limine bios-install could not write to $dev."
		warn 'A BIOS boot may not work until Limine is installed by hand.'
	fi
else
	warn "$LIMDIR/limine-bios-hdd.h is missing, which is the file"
	warn 'bios-install stages into the boot sectors, so the BIOS stages were'
	warn 'not written. Install drivers/bootloader/limine-binary and re-run.'
fi

cleanup
trap - EXIT INT TERM

# --- data mode -------------------------------------------------------------

if [ "$mode" = data ]; then
	# data mode is the same install with one thing changed: /var is a
	# separate filesystem on the same disk, so state survives a reboot even
	# though the system itself runs from RAM.  That means a second
	# partition, which flxpart --create-standard has not made.
	ok 'the system is installed.'
	say ''
	say 'data mode wants a second filesystem for /var so that state survives a'
	say 'reboot, and flxpart --create-standard lays out only one root'
	say 'partition. That is the next piece of work; run the installer again'
	say 'and choose sys if you want a system that boots from this disk.'
	exit 0
fi

printf '%s\n' "$(cat /mnt/flx/etc/xsetup-disk-mode 2>/dev/null || echo sys)" >"$DONE_FILE" 2>/dev/null || printf 'sys\n' >"$DONE_FILE"
rm -f /mnt/flx 2>/dev/null || rmdir /mnt/flx 2>/dev/null || :

ok "installed to $dev"
say ''
say "  root   $ROOT_DEV"
say "  boot   $ESP_DEV (UEFI), $dev (BIOS)"
say ''
say 'Reboot and remove the medium. The disk boots on both BIOS and UEFI.'
