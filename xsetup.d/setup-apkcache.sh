#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-apkcache - choose where downloaded package files are kept.
#
# Only meaningful when the system runs from RAM.  xpkg's cache defaults to
# /var/cache/xpkg, which on a RAM system is RAM, so every install re-downloads
# what was downloaded an hour earlier.  Pointing the cache at a disk is the
# whole point of this step.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

MODE=none
[ -f /etc/xsetup-disk-mode ] && MODE=$(cat /etc/xsetup-disk-mode)

case $MODE in
sys)
	ok 'the system is on a disk, so /var/cache/xpkg is already on one'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
	;;
esac

info "disk mode is $MODE, so this step applies"

DEFAULT=/var/cache/xpkg

where=$(choose 'Where should downloaded package files be kept?' \
	ram 'in RAM, lost on reboot' \
	disk 'on a disk, so they survive a reboot')

if [ "$where" = ram ]; then
	printf 'XPKG_CACHE=%s\n' "$DEFAULT" >/etc/xpkg/cache.conf
	mkdir -p "$DEFAULT"
	ok "package cache stays in $DEFAULT (lost on reboot)"
	return 0
fi

devs=
for p in /dev/sd? /dev/nvme?n? /dev/vd?; do
	[ -b "$p" ] || continue
	devs="$devs $p"
done

if [ -z "$devs" ]; then
	warn 'no disk was found, so the cache cannot be kept on one.'
	warn 'Downloads will be repeated on every boot.'
	printf 'XPKG_CACHE=%s\n' "$DEFAULT" >/etc/xpkg/cache.conf
	ok 'package cache stays in RAM (no disk present)'
	return 0
fi

info 'disks found:'
for d in $devs; do
	printf '  %-14s %s\n' "$d" \
		"$(df -h "$d" 2>/dev/null | awk 'NR==2 {print $2" total, "$4" free"}')"
done

# shellcheck disable=SC2086
# "none" needs a label as well as a value.  A bare `none` is one word where an
# entry is two, so the count comes out odd and choose refuses the menu outright:
#
#     error: choose: "Which disk holds the package cache" was given an odd
#            number of arguments
#
dev=$(choose 'Which disk holds the package cache' none 'no disk, keep it in RAM' \
	$(for d in $devs; do printf '%s %s ' "$d" "$d"; done))
[ "$dev" = none ] && die 'no disk was chosen, so the cache stays in RAM'

warn "about to write to $dev"
confirm "This writes to $dev" || die 'nothing was changed'

# A real directory on the chosen disk, not a symlink into RAM: the point is
# that it survives a reboot.
mnt=/var/cache/xpkg-disk
mkdir -p "$mnt"

printf '%s\t%s\t%s\t%s\t0\t0\n' "$dev" /var/cache/xpkg-disk vfat defaults 0 0 \
	>/etc/fstab.lbu

mkdir -p /etc/xpkg
{
	printf '# Written by xsetup.\n'
	printf 'XPKG_CACHE=%s\n' "$mnt"
} >/etc/xpkg/cache.conf

ok "package cache will be kept on $dev under $mnt"
say ''
say 'The cache directory is created and /etc/fstab.lbu records the disk, but'
say 'nothing mounts it yet: mounting is done by the image build, and until'
say 'then the cache is written to the RAM copy.'
