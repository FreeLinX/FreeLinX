#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-lbu - choose where a backup overlay is kept.
#
# Only meaningful when the system runs from RAM (disk mode none or data).
# Every change is written into an overlay, and this is where that overlay
# lives.  On a diskless machine it has to be somewhere that survives a
# reboot, or the answer is "nowhere", which is a legitimate answer and the
# one a machine with no disk gets by default.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

MODE=none
[ -f /etc/xsetup-disk-mode ] && MODE=$(cat /etc/xsetup-disk-mode)

case $mode in
sys)
	ok 'the system is installed on a disk, so an overlay is not needed'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
	;;
esac

info "disk mode is $MODE, so this step applies"

where=$(choose 'Where should the local backup overlay be kept?' \
	none 'nowhere, changes are lost on reboot' \
	disk 'on a disk, so changes survive a reboot')

printf 'LBU_MEDIA=%s\n' "$where" >/etc/conf.d/lbu.conf 2>/dev/null || {
	mkdir -p /etc/conf.d
	printf 'LBU_MEDIA=%s\n' "$where" >/etc/conf.d/lbu.conf
}

case $where in
none)
	warn 'nothing will be kept. Every change is lost when the machine'
	warn 'reboots, and the image has to be booted again to get a system.'
	ok 'overlay storage: none'
	return 0
	;;
disk)
	# A disk that is not there cannot be the answer, so the device is
	# asked for explicitly rather than guessed.
	devs=
	for p in /dev/sd? /dev/nvme?n? /dev/vd?; do
		[ -b "$p" ] || continue
		devs="$devs $p"
	done

	if [ -z "$devs" ]; then
		warn 'no disk was found, so the overlay cannot be kept on one.'
		warn 'Falling back to nowhere: changes will be lost on reboot.'
		printf 'LBU_MEDIA=none\n' >/etc/conf.d/lbu.conf
		ok 'overlay storage: none (no disk present)'
		return 0
	fi

	info 'disks found:'
	for d in $devs; do
		printf '  %-14s %s\n' "$d" \
			"$(df -h "$d" 2>/dev/null | awk 'NR==2 {print $2" total, "$4" free"}')"
	done

	# shellcheck disable=SC2086
	dev=$(choose 'Which disk holds the overlay' none 'leave it alone' \
		$(for d in $devs; do printf '%s %s ' "$d" "$d"; done))
	[ "$dev" = none ] && die 'no disk was chosen, so the overlay stays unset'

	warn "about to write to $dev"
	confirm "This writes to $dev" || die 'nothing was changed'

	mkdir -p /etc/conf.d
	{
		printf '# Written by xsetup.\n'
		printf 'LBU_MEDIA=%s\n' "$dev"
		printf 'LBU_PATH=/var/lbu\n'
	} >/etc/conf.d/lbu.conf

	ok "overlay will be kept on $dev under /var/lbu"
	;;
esac
