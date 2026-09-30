#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-disk - choose how the system is stored.
#
#   sys    install onto a disk: partition, format, copy the system across
#   data   run from RAM, keep a disk for /var
#   none   run from RAM and touch no disk at all
#
# sys and data both write to a disk and both destroy what is on the chosen
# one, so they are never selected by accident and never by a default.
# none is safe and is the default, because an installer that guesses a disk
# is an installer that eats laptops.

need_root

# Written to /etc so setup-lbu and setup-apkcache can see the answer.
DISK_MODE_FILE=/etc/xsetup-disk-mode

mode=$(choose 'How should the system be stored?' \
	none 'run from RAM, no disk is written' \
	sys 'install onto a disk (erases it)' \
	data 'run from RAM, keep a disk for /var (erases it)')

printf '%s\n' "$mode" >"$DISK_MODE_FILE"

case $mode in
none)
	ok 'running from RAM. Nothing is written to any disk.'
	say ''
	say 'Steps 12 (setup-lbu and setup-apkcache) apply to this mode: they'
	say 'decide where a backup overlay and the package cache are kept.'
	exit 0
	;;
esac

info 'this will erase the disk you choose. There is no undo.'

# Every whole block device, with its size, so the choice is informed.
disks() {
	_d=
	for p in /dev/sd? /dev/nvme?n? /dev/vd? /dev/hd?; do
		[ -b "$p" ] || continue
		_d=$d${_d:+ }$p
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
	printf '  %-14s %s\n' "$d" "$(df -h "$d" 2>/dev/null | awk 'NR==2 {print $2" total, "$4" used"}')"
done
printf '\n'

dev=$(choose 'Which disk' none $(for d in $devs; do printf '"%s" ' "$d"; done | sed 's/ *$//'))
[ "$dev" = none ] && die 'no disk was chosen, so nothing was written'

printf '\n'
warn "about to erase $dev, and everything on it"
confirm "This erases $dev" || die 'nothing was changed'

# The partitioner.  flxpart is the FreeLinX one; it is not built into this
# image yet, and writing GPT here instead would mean two partitioners in the
# project with two behaviours.
need_cmd flxpart 'the sysutils/flxpart port'

info "partitioning $dev"
flxpart --create-standard --esp-size 256 "$dev" ||
	die "flxpart could not partition $dev"

ok "$dev partitioned"
ok 'chose sys/data mode: the system copy and bootloader install are not done'
say ''
say 'flxpart laid out the partition table and stopped there. Formatting,'
say 'extracting the system and installing the bootloader are the next pieces'
say 'of work; nothing has been written to the partitions.'
