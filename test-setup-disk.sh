#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-setup-disk.sh - exercise setup-disk.sh without a disk.
#
# The step is irreversible, and the parts most likely to be wrong -- which
# device node is which partition, what the geometry is, whether the tools
# exist -- are all decidable before anything is written.  So it runs with
# XSETUP_DRY_RUN=1 against a plain file standing in for a disk, and is checked
# for the decisions rather than for the destruction.
#
# What this does NOT cover, and does not pretend to: mkfs, the system copy,
# the bootloader and fstab.  Those need a real block device and root, and are
# untested here.
set -u

BASE=$(cd "$(dirname "$0")" && pwd)
STEP=$BASE/xsetup.d/setup-disk.sh
UI=$BASE/lib/ui.sh
ROOTFS=${ROOTFS:-/home/kanan/FreeLinX/src/rootfs}
FLXPART=${FLXPART:-$ROOTFS/sbin/flxpart}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1)); printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1))
		printf '  FAIL %s\n        want [%s]\n        got  [%s]\n' "$1" "$3" "$2"
	fi
}

contains() {
	if printf '%s' "$2" | grep -qF -- "$3"; then
		pass=$((pass + 1)); printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1))
		printf '  FAIL %s: output has no [%s]\n' "$1" "$3"
		printf '%s\n' "$2" | sed 's/^/        /' | head -14
	fi
}

DISK=$TMP/disk.img
truncate -s 4G "$DISK"

# run_step ANSWERS - feed ANSWERS to the step, in a scratch cwd, with the
# image's own tools on PATH and a dry run forced.
run_step() {
	( cd "$TMP" || exit 1
	  PATH=$ROOTFS/sbin:$ROOTFS/bin:$ROOTFS/usr/bin:$ROOTFS/usr/sbin:/usr/bin:/bin
	  export PATH
	  XSETUP_DRY_RUN=1
	  XSETUP_DISK_OVERRIDE=$DISK
	  FLXPART=$FLXPART
	  XSETUP_STATE_FILE=$TMP/mode
	  export XSETUP_DRY_RUN XSETUP_DISK_OVERRIDE FLXPART XSETUP_STATE_FILE
	  printf '%s' "$1" | sh "$STEP" 2>&1
	)
}

nonzero() { tr -d '\0' <"$DISK" | wc -c | tr -d ' '; }

echo '== a dry run says so, and writes nothing =='
out=$(run_step '2
2
yes
')
contains 'says dry run' "$out" 'dry run'
ok 'the disk is untouched' "$(nonzero)" '0'

echo '== RAM mode touches nothing and writes no mode =='
rm -f "$TMP/mode"
out=$(run_step '1
')
contains 'says running from RAM' "$out" 'running from RAM'
# The mode file is written even for RAM, because steps 12 read it to decide
# whether they apply.  Asserting it was absent would have been asserting the
# bug that steps 12 would then hit.
ok 'the mode is recorded as none' "$(cat "$TMP/mode" 2>/dev/null)" 'none'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== sys mode reports the real geometry, and partitions nothing =='
out=$(run_step '2
2
yes
')
contains 'says dry run' "$out" 'dry run'
contains 'names the EFI system partition' "$out" 'EFI system'
contains 'names the BIOS boot partition' "$out" 'BIOS boot'
contains 'resolves the root device' "$out" 'root'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== declining the confirmation changes nothing =='
out=$(run_step '2
2
no
')
contains 'refuses' "$out" 'nothing was changed'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== the override is refused without a dry run =='
# need_root comes first and this host is not root, so the override refusal is
# checked with a fake id(1) that reports 0.  That is the only way to reach the
# check here; the check itself is not conditional on being root.
out=$( cd "$TMP" && mkdir -p bin && printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || exec /usr/bin/id "$@"\n' > bin/id \
	&& chmod +x bin/id
	  PATH=$TMP/bin:$ROOTFS/sbin:$ROOTFS/bin:$ROOTFS/usr/bin:$ROOTFS/usr/sbin:/usr/bin:/bin \
	  XSETUP_DRY_RUN=0 XSETUP_DISK_OVERRIDE=$DISK \
	  XSETUP_STATE_FILE=$TMP/mode sh "$STEP" </dev/null 2>&1 )
contains 'refuses the override' "$out" 'only honoured with --dry-run'

echo '== need_cmd names the port that would supply the tool =='
out=$( printf '' | sh -c "PATH=/usr/bin:/bin; . $UI; need_cmd definitely_not_here 'the some/port' 2>&1" )
contains 'names the port' "$out" 'the some/port'
out=$( printf '' | sh -c "PATH=$ROOTFS/sbin:/usr/bin:/bin; . $UI; need_cmd flxpart 'the sysutils/flxpart port' 2>&1; echo rc=\$?" )
contains 'a present command passes' "$out" 'rc=0'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
cat <<'NOTE'

This suite is the conversation: the geometry, the confirmations, the guards, and
that a dry run touches nothing.  The commands a real run executes -- flxpart
writing a table, mkfs.fat, mkfs.ext4, blkid, the copy, the fstab -- are covered
by test-destructive.sh, which runs them against image files with the rootfs's own
binaries.  What neither suite can do is mount, so the copy crossing into a real
filesystem and limine bios-install on the boot sectors are still untested: those
need root and a block device.
NOTE
exit $([ "$fail" -eq 0 ]; echo $?)
