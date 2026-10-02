#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# guest-install.sh - run inside the QEMU guest, unattended.
#
# This is the script that makes the destructive installer testable.  The
# installer is interactive by design: it asks how to store the system, which
# disk, and for a typed 'yes' before it erases anything.  That is correct
# behaviour and this script does not change it -- it drives the same prompts
# from a pipe, and every answer it gives is one a person could have given.
#
# It runs the one step that destroys things, setup-disk, in 'sys' mode against
# the scratch disk, and then verifies the result by reading the partitions back.
# The point is not that the installer exits 0; it is that the disk afterwards has
# what the installer said it put there.
#
# Every check reads the disk with an independent tool - blkid, dd, mount - so a
# check cannot pass by believing the installer's own report of what it did.
#
# Output goes to stdout, which is the guest console, because that is where the
# host reads it from.  Two lines per check: a readable one, and one the host
# parses (`ok N ...` / `no N ...`), plus a `summary passed=N failed=N` at the
# end so a truncated log cannot be mistaken for a clean run.

set -u

DEV=${FLX_TEST_DISK:-/dev/vda}
MNT=/mnt/flx

# Which mode to install in.  sys is the default because that is the install that
# has to work; data is the other one, and it is a different install on purpose -
# see the data-mode section near the end.
#
# Read from the environment rather than hardcoded, so the same guest script can
# check both against the same disk.  A missing value falls back to sys rather than
# to an empty string, which would match no case and quietly install nothing.
MODE=${FLX_TEST_MODE:-sys}
case $MODE in
sys|data) ;;
*)
	printf 'no 0 FLX_TEST_MODE is %s; it must be sys or data\n' "$MODE"
	printf 'summary passed=0 failed=1\n'
	printf 'FLX-TEST-DONE\n'
	exit 1
	;;
esac

# The menu numbers from 1 and the real choices come after 'run from RAM' (1), so
# sys is the second choice and data the third.  Computed here rather than written
# at the point of use, so the two places that answer the menu cannot disagree: a
# menu answered with the wrong number selects the wrong install and the installer
# reports success.
if [ "$MODE" = sys ]; then
	MODE_ANSWER=2
else
	MODE_ANSWER=3
fi

say() { printf '%s\n' "$*"; }

n=0
passed=0
failed=0

# pass DESCRIPTION - a check that held.
pass() {
	n=$((n + 1))
	passed=$((passed + 1))
	printf '  ok   %s\n' "$1"
	printf 'ok %d %s\n' "$n" "$1"
}

# fail DESCRIPTION - a check that did not hold.  It keeps going rather than
# exiting, because the point of the run is to find out everything that is wrong
# with the install, and the first thing to go wrong is rarely the last.
fail() {
	n=$((n + 1))
	failed=$((failed + 1))
	printf '  FAIL %s\n' "$1"
	printf 'no %d %s\n' "$n" "$1"
}

# check DESCRIPTION ACTUAL EXPECTED - equality, reported with both values.
check() {
	if [ "$2" = "$3" ]; then
		pass "$1"
	else
		fail "$1 (got '$2', wanted '$3')"
	fi
}

# bail DESCRIPTION - the run cannot continue at all.
bail() {
	printf 'FATAL %s\n' "$*"
	printf 'no %d cannot continue: %s\n' "$((n + 1))" "$*"
	printf 'summary passed=%d failed=%d\n' "$passed" "$((failed + 1))"
	printf 'FLX-TEST-DONE\n'
	exit 1
}

say '=== FreeLinX destructive install test, in-guest ==='
say "disk: $DEV"
say "uid:  $(id -u)"

# --- the medium --------------------------------------------------------------

MNTMED=/cdrom
found=already-mounted
if [ ! -f "$MNTMED/guest-install.sh" ]; then
	found=
	for d in /dev/sr0 /dev/sr1 /dev/cdrom /dev/vdb; do
		[ -b "$d" ] || continue
		mkdir -p "$MNTMED"
		if mount -t iso9660 -o ro "$d" "$MNTMED" 2>/dev/null; then
			found=$d
			break
		fi
	done
	[ -n "$found" ] || bail 'the installer medium did not mount and no cdrom device appeared'
fi
say "medium: $found at $MNTMED"
[ -f "$MNTMED/installer/xsetup.d/setup-disk.sh" ] ||
	bail "there is no installer on the medium at $MNTMED/installer"

# --- the tools the installer needs -------------------------------------------
#
# Checked here so a missing one is named, instead of showing up much later as
# an unexplained failure somewhere inside the installer.

for c in flxpart mkfs.ext4 mkfs.fat tar limine blkid; do
	command -v "$c" >/dev/null 2>&1 || bail "$c is not in this image"
done
pass 'every tool the installer needs is present'

[ -b "$DEV" ] || bail "$DEV is not a block device"

BEFORE=$(blkid -o value -s TYPE "$DEV" 2>/dev/null || printf none)
say "partition table before: ${BEFORE:-none}"

# --- run the installer -------------------------------------------------------
#
# 1 = 'install onto a disk', then the disk number, then a typed 'yes'.  A
# heredoc rather than a pipe into sh, because `sh` reads the script from the pipe
# too when it is given `-`; here sh runs a file and reads answers from stdin.
say '--- running setup-disk ---'
# Both menus number from 1 with 'leave it alone' / 'run from RAM' first, so the
# disk is always the second choice.  $MODE_ANSWER is the mode; the last answer is
# the typed confirmation of the erase.
printf '%s\n%s\nyes\n' "$MODE_ANSWER" 2 >/tmp/flx-answers
say "mode: $MODE (menu answer $MODE_ANSWER)"
if sh "$MNTMED/installer/xsetup.d/setup-disk.sh" </tmp/flx-answers 2>&1
then
	say 'setup-disk exited 0'
else
	_rc=$?
	say "setup-disk exited $_rc"
	# What the disk actually looks like from here.  setup-disk says it wrote a
	# table and formatted filesystems; these are the kernel's own view of the
	# same thing, and when the two disagree this is the difference that matters.
	say '--- diagnostics after the failure ---'
	say "  /proc/partitions:"; sed 's/^/    /' /proc/partitions 2>/dev/null
	say "  /dev/vda*:"; ls -l /dev/vda* 2>&1 | sed 's/^/    /'
	for p in /dev/vda /dev/vda1 /dev/vda2 /dev/vda3; do
		[ -e "$p" ] || continue
		say "  $p: type=$(blkid -o value -s TYPE "$p" 2>&1) size=$(blockdev --getsize64 "$p" 2>&1)"
	done
	say "  blockdev --getsize64 /dev/vda3: $(blockdev --getsize64 /dev/vda3 2>&1)"
	# Which filesystems this kernel can mount at all, read from the kernel
	# itself.  If ext4 is missing here then the mke2fs that just succeeded
	# produced a filesystem nothing can mount, and the ENODEV is the kernel
	# saying exactly that.
	say "  /proc/filesystems (ext4/vfat):"
	sed 's/^/    /' /proc/filesystems 2>/dev/null | grep -iE 'ext4|vfat|fat' ||
		say '    (neither ext4 nor vfat is listed)'
	say "  mount -t ext4:  $(mount -t ext4 /dev/vda3 /mnt/flx 2>&1)"
	mkdir -p /mnt/esp
	say "  mount -t vfat:  $(mount -t vfat /dev/vda1 /mnt/esp 2>&1)"
	say "--- end diagnostics ---"
	fail "setup-disk exited $_rc"
	umount "$MNT" 2>/dev/null || :
	printf 'summary passed=%d failed=%d\n' "$passed" "$failed"
	printf 'FLX-TEST-DONE\n'
	exit 1
fi
sed 's/^/  | /' /tmp/flx-setup-disk.out 2>/dev/null || true
say '--- setup-disk finished ---'

umount "$MNT" 2>/dev/null || :

# --- the disk afterwards -----------------------------------------------------

say '--- verifying ---'

# hexat FILE OFFSET COUNT - COUNT bytes at OFFSET as lowercase hex.
#
# od's -v matters and its absence is invisible until it matters: without it od
# collapses runs of identical output lines into a single `*`, so a sector that
# is mostly zeros comes back looking like one short line of hex with a `*` in
# it, and a search for sixteen consecutive zeros in the result finds them in
# padding that was never on the disk.  That is how a check for "the boot sector
# was written" once reported that a boot sector with Limine's own signature in
# it was blank.
hexat() {
	dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null |
		od -An -tx1 -v | tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f'
}

# u16 FILE OFFSET - the little-endian 16-bit field at OFFSET, as a decimal.
#
# Not `od -An -tu2`: this system's od zero-pads to five digits, so a zero field
# comes back as "00000" and nothing equals 0.  Two single bytes assembled by
# hand has no padding to strip.
u16() {
	_lo=$(dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tx1 | tr -cd '0-9a-fA-F')
	_hi=$(dd if="$1" bs=1 skip=$(( $2 + 1 )) count=1 2>/dev/null | od -An -tx1 | tr -cd '0-9a-fA-F')
	printf '%s' $(( 0x${_lo:-0} + 0x${_hi:-0} * 256 ))
}

# 1. A GPT is on the disk.  Read the two structures that make it a GPT rather
#    than asking blkid what it thinks the whole device is: the protective MBR
#    with its 0x55 0xAA signature at bytes 510-511, and the "EFI PART" signature
#    at the start of the GPT header in sector 1.  Either alone would do; both
#    together mean it was not a coincidence.
mbrsig=$(dd if="$DEV" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f')
gpthdr=$(dd if="$DEV" bs=1 skip=512 count=8 2>/dev/null | tr -cd 'A-Z ')
say "protective MBR signature: $mbrsig"
say "GPT header: '$gpthdr'"
check 'the disk has a protective MBR signature' "$mbrsig" 55aa
check 'the disk has a GPT header' "$gpthdr" 'EFI PART'

# 2. The partitions the installer promised are readable back, and the ESP is
#    FAT.  Read with blkid, which parses the on-disk structures.
ESP=
ROOT=
i=1
while [ "$i" -le 8 ]; do
	_p=$DEV$i
	[ -b "$_p" ] || break
	_t=$(blkid -o value -s TYPE "$_p" 2>/dev/null || printf none)
	_l=$(blkid -o value -s LABEL "$_p" 2>/dev/null || printf '')
	_u=$(blkid -o value -s UUID "$_p" 2>/dev/null || printf '')
	say "  $_p type=$_t label=$_l uuid=$_u"
	case $_t in
	vfat) ESP=$_p ;;
	ext2|ext3|ext4) ROOT=$_p ;;
	esac
	i=$((i + 1))
done

[ -n "$ESP" ] || bail 'no FAT partition: the ESP was not created or is not vfat'
[ -n "$ROOT" ] || bail 'no ext partition: the root filesystem was not created'
pass 'both an ESP and a root filesystem exist and are readable'

# 3. The ESP is FAT32, confirmed from the BIOS parameter block rather than from
#    the word 'vfat'.  Together these two fields are what makes a FAT volume
#    FAT32: a zero 16-bit sector-count field, and no reserved root entries.
bpb_fatsz16=$(u16 "$ESP" 22)
bpb_rootent=$(u16 "$ESP" 17)
say "  BPB_FATSz16=$bpb_fatsz16 BPB_RootEntCnt=$bpb_rootent"
check 'the ESP is FAT32 (BPB_FATSz16 is 0)' "$bpb_fatsz16" 0
check 'the ESP is FAT32 (no reserved root directory entries)' "$bpb_rootent" 0

# 4. The ESP carries the UEFI boot loader, and only there.  This is the first
#    bug this test exists for: the ESP was never mounted, so BOOTX64.EFI was
#    written into the ext4 root at /boot/efi/EFI/BOOT, where no firmware ever
#    looks, and a UEFI install produced a boot target on nothing.
mkdir -p /mnt/esp
# -t for the same reason setup-disk.sh names its types: this mount does not
# guess an unspecified filesystem, it fails with ENODEV.
mount -t vfat "$ESP" /mnt/esp || bail "could not mount the ESP $ESP"
if [ -f /mnt/esp/EFI/BOOT/BOOTX64.EFI ]; then
	pass 'BOOTX64.EFI is on the ESP where UEFI firmware looks for it'
else
	fail 'BOOTX64.EFI is not on the ESP'
fi
# And the ESP must not be a directory that exists but is otherwise empty of it,
# which is what a half-finished copy looks like.
if [ -d /mnt/esp/EFI ] && [ ! -e /mnt/esp/EFI/BOOT/BOOTX64.EFI ]; then
	fail 'the ESP has an EFI directory but no BOOTX64.EFI inside it'
else
	pass 'the ESP has no empty EFI directory left behind'
fi
umount /mnt/esp

# 5. A real system is on the root filesystem, including what Limine needs to
#    find the kernel.
mkdir -p /mnt/root
mount -t ext4 "$ROOT" /mnt/root || bail "could not mount the root filesystem $ROOT"
# What actually landed.  The per-file checks below say which paths are missing;
# this says how much of the tree arrived, so a copy that stopped early is
# distinguishable from a copy that put the files somewhere else.
say "  installed root: $(ls /mnt/root | tr '\n' ' ')"
say "  /mnt/root entry count: $(find /mnt/root | wc -l | tr -d ' ')"
say "  /mnt/root/bin: $(ls /mnt/root/bin 2>&1 | head -c 120)"
say "  /mnt/root/usr/bin: $(ls /mnt/root/usr/bin 2>&1 | head -c 120)"
for f in init bin/sh sbin/runsvdir bin/mount; do
	if [ -e "/mnt/root/$f" ]; then
		pass "/$f is on the root filesystem"
	else
		fail "/$f is missing from the root filesystem"
	fi
done

# 6. Hard links survived the copy.  This is the second bug: the copy used to be
#    `cp -a`, and the cp in this system is NetBSD's, whose -a does not preserve
#    hard links, so a system with hundreds of names sharing one zoneinfo inode
#    got installed as hundreds of separate copies.
#
#    Checked by counting, not by picking a file: a check that takes the first
#    name find reports and asks whether it has more than one link is asking about
#    whichever zone happens to sort first, and most zones are not linked to
#    anything.  The question worth asking is whether the tree has fewer inodes
#    than it has files.
#
#    Also not by find -samefile: this system's find is NetBSD's and has no
#    -samefile option at all, so a check written with it matches nothing and
#    calls the copy broken when it is fine.
_zdir=/mnt/root/usr/share/zoneinfo
ZT=/tmp/flx-dtest-zoneinfo.ls
ZTI=/tmp/flx-dtest-zoneinfo.inodes
if [ -d "$_zdir" ]; then
	_zfiles=$(find "$_zdir" -type f 2>/dev/null | wc -l | tr -d ' ')
	# Through files, and through a file for sort rather than a pipe.  This
	# system's sort opens /dev/stdin to read a pipe, and /dev/stdin is not a
	# name that exists unless init makes it; that is fixed in init too, but a
	# check should not need both fixes to be in place before it can say yes.
	ls -liR "$_zdir" >"$ZT" 2>/dev/null
	awk '$1 ~ /^[0-9]+$/ && NF > 6 { print $1 }' "$ZT" >"$ZTI" 2>/dev/null
	sort -u "$ZTI" >"$ZTI.u" 2>/dev/null
	_zinodes=$(wc -l <"$ZTI.u" 2>/dev/null | tr -d ' ')
	say "  zoneinfo: $_zfiles files, $_zinodes distinct inodes"
	if [ -n "$_zfiles" ] && [ "$_zfiles" -gt 0 ] 2>/dev/null &&
	   [ -n "$_zinodes" ] && [ "$_zinodes" -gt 0 ] 2>/dev/null &&
	   [ "$_zinodes" -lt "$_zfiles" ] 2>/dev/null; then
		pass "zoneinfo hard links were preserved ($_zfiles names on $_zinodes inodes)"
	else
		fail "zoneinfo hard links were NOT preserved: $_zfiles files on ${_zinodes:-0} inodes, so every zone is its own copy"
	fi
	rm -f "$ZT" "$ZTI" "$ZTI.u"

	# And one named link, so the count above is not the only evidence.
	# Distinct values are the point: two names reporting the same inode twice is
	# a pass, and counting the words in the output instead makes that read as a
	# fail, which is what it did.
	ls -i "$_zdir/GB" "$_zdir/Europe/London" 2>/dev/null |
		awk 'NF >= 2 { print $1 }' >"$ZT" 2>/dev/null
	sort -u "$ZT" >"$ZTI" 2>/dev/null
	_zshared=$(wc -l <"$ZTI" 2>/dev/null | tr -d ' ')
	_znames=$(wc -l <"$ZT" 2>/dev/null | tr -d ' ')
	say "  GB and Europe/London: $_znames names, $_zshared distinct inodes"
	if [ "$_znames" -eq 2 ] && [ "$_zshared" -eq 1 ] 2>/dev/null; then
		pass 'GB and Europe/London are one inode on the installed system'
	else
		fail "GB and Europe/London do not share an inode on the installed system: $_znames names, $_zshared inodes"
	fi
	rm -f "$ZT" "$ZTI"
else
	fail 'there is no zoneinfo on the installed root, so hard links cannot be checked'
fi

# 7. fstab names devices by UUID, not by /dev/vdaN.  A disk installed as vda will
#    not be sda on the machine it is booted on, so an fstab with device nodes in
#    it is an fstab that stops the next boot from finding root at all.
if [ -f /mnt/root/etc/fstab ]; then
	fstab=$(cat /mnt/root/etc/fstab)
	say "  fstab: $(printf '%s' "$fstab" | tr '\n' '|')"
	# Matched anywhere in the file, not only at the start of the first line:
	# an fstab whose first entry is a comment does not begin with UUID= and
	# was reported as having no UUID at all while its second line had one.
	case $fstab in
	*UUID=*) pass 'fstab identifies the root filesystem by UUID' ;;
	*)       fail 'fstab does not use UUID= for the root filesystem' ;;
	esac

	# ... and that UUID has to be this disk's, or the next boot looks for a
	# filesystem that does not exist.
	_want=$(blkid -o value -s UUID "$ROOT")
	_have=$(printf '%s' "$fstab" | sed -n 's/.*UUID=\([0-9a-fA-F-]*\).*/\1/p' | head -1)
	say "  fstab root uuid=$_have  actual on disk=$_want"
	if [ -n "$_want" ] && [ "$_have" = "$_want" ]; then
		pass 'the UUID in fstab is this disk'
	else
		fail "the UUID in fstab is not this disk (fstab says ${_have:-nothing}, disk says ${_want:-nothing})"
	fi
else
	fail 'there is no /etc/fstab on the installed root'
fi

# le FILE OFFSET NBYTES - a little-endian unsigned integer of NBYTES, as decimal.
#
# The byte pairs have to be turned over, because od prints them in file order
# and a little-endian number reads the other way round.  That is awk's `out = $i
# out`: each pair goes to the front, so the last byte ends up first.
#
# Two ways of doing this that do not work, both of which produce a number and so
# look fine: this system's od zero-pads decimal output to five digits, so
# `-tu1` renders byte 34 as "002" and every field comes out two and a half
# times too small; and taking the last pair with ${_h#"${_h%??}"} in a shell loop
# rebuilds the original order, because the pair taken first ends up at the end.
le() {
	_h=$(dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null |
		od -An -tx1 -v |
		awk '{ out = ""; for (i = 1; i <= NF; i++) out = $i out; printf "%s", out }')
	printf '%s' "$(( 0x${_h:-0} ))"
}

# guid_canon FILE BYTEOFFSET - the 8-4-4-4-12 reading of the 16 type bytes at
# BYTEOFFSET.
#
# A GPT stores a GUID mixed-endian, so what is on the disk is not the GUID it
# names until it is reassembled: the first three fields are little-endian and
# the last two big-endian.  This is the form the UEFI specification and the
# Limine source are both written in, and it is the form to compare against.
#
# It takes an offset rather than a string of hex because the guest's /bin/sh is
# POSIX and has no ${x:off:len}, and cutting the hex up with cut is sixteen
# processes where reading the bytes once is none.
#
# The five fields are 4, 2, 2, 2 and 6 bytes, so the offsets are 0, 4, 6, 8 and
# 10.  The last two are big-endian and come out of hexat as they are stored; the
# first three go through le.
guid_canon() {
	_d1=$(le "$1" "$2" 4)
	_d2=$(le "$1" $(( $2 + 4 )) 2)
	_d3=$(le "$1" $(( $2 + 6 )) 2)
	_d4=$(hexat "$1" $(( $2 + 8 )) 2)
	_d5=$(hexat "$1" $(( $2 + 10 )) 6)
	guid_canon_out=$(printf '%08X-%04X-%04X-%s-%s' "$_d1" "$_d2" "$_d3" "$_d4" "$_d5" |
		tr 'a-f' 'A-F')
	printf '%s' "$guid_canon_out"
}

# gpt_off PARTINDEX - byte offset in the disk of partition PARTINDEX's entry.
#
# The header is in sector 1 and points at the entry array, which is not at a
# fixed place - flxpart puts it in sector 2 here, and the specification allows
# anywhere - so its LBA is read rather than assumed.
#
# The field offsets are within the header: the array LBA is at 72, the entry
# count at 80 and the entry size at 84, so in the disk they are at 584, 592 and
# 596.  592 is the count and not the size; both are 128 on a standard layout,
# which is why reading the wrong one looks correct.
gpt_off() {
	printf '%s' $(( $(le "$DEV" 584 8) * 512 + ($1 - 1) * $(le "$DEV" 596 4) ))
}

# 8. The partition table's own type GUIDs, and Limine's BIOS stages.
#
#    Two things have to be true, and either alone would pass while the machine
#    still does not boot:
#
#      sector 0 is a boot sector - it opens with a jump (0xEB), where a plain GPT
#      protective MBR that nothing has written to is 446 zero bytes, and it
#      carries Limine's own "LIMINE" marker, which says who put it there rather
#      than merely that something did
#
#      the BIOS boot partition holds Limine's next stage - this is where
#      bios-install put the code that loads limine-bios.sys, and on a GPT disk
#      it chooses that partition by type GUID
#
#    Which partition that is, is read out of the table the installer wrote, and
#    the three type GUIDs are compared with the ones firmware and Limine look
#    for.  A wrong type is the whole failure: the partition is created, it is
#    the right size, it is named correctly, and nothing finds it.
bios_idx=
esp_idx=
root_idx=
i=1
while [ "$i" -le 16 ]; do
	_off=$(gpt_off "$i")
	_raw=$(hexat "$DEV" "$_off" 16)
	[ "$_raw" = 00000000000000000000000000000000 ] && break
	_canon=$(guid_canon "$DEV" "$_off")
	say "  GPT partition $i type $_canon"
	# Written out for the data-mode section to read with its own eyes.  It
	# re-reads the table rather than reusing esp_idx and the rest, because a
	# check that shares its reader with the thing it checks cannot disagree
	# with it - and "the data disk has no ESP partition" has to be able to
	# fail.
	printf 'partition %s type %s\n' "$i" "$_canon" >>/tmp/flx-gpt.txt
	case $_canon in
	C12A7328-F81F-11D2-BA4B-00A0C93EC93B) esp_idx=$i ;;
	21686148-6449-6E6F-744E-656564454649) bios_idx=$i ;;
	0FC63DAF-8483-4772-8E79-3D69D8477DE4) root_idx=$i ;;
	esac
	i=$((i + 1))
done

if [ -n "$esp_idx" ]; then
	pass 'the ESP carries the type GUID firmware looks for'
else
	fail 'no partition in the table has the EFI System Partition type GUID'
fi
if [ -n "$bios_idx" ]; then
	pass 'the BIOS boot partition carries the type GUID Limine looks for'
else
	fail 'no partition in the table has the BIOS Boot Partition type GUID'
fi
if [ -n "$root_idx" ]; then
	pass 'the root filesystem carries the Linux filesystem data type GUID'
else
	fail 'no partition in the table has the Linux filesystem data type GUID'
fi

mbr_jump=$(hexat "$DEV" 0 1)
mbr_hex=$(hexat "$DEV" 0 512)
say "  sector 0 byte 0: $mbr_jump"
check 'the boot sector opens with a jump instruction' "$mbr_jump" eb

# "LIMINE" as hex, so the search is for those five bytes and not for a text
# match that a hex dump would never contain.
case $mbr_hex in
*4c494d494e45*) mbr_marked=yes ;;
*)              mbr_marked=no ;;
esac
say "  sector 0 carries the LIMINE marker: $mbr_marked"
check 'the boot sector carries Limine' "$mbr_marked" yes

if [ -n "$bios_idx" ]; then
	_lba=$(le "$DEV" $(( $(gpt_off "$bios_idx") + 32 )) 8)
	_at=$(( _lba * 512 ))
	bios_jump=$(hexat "$DEV" "$_at" 1)
	case $(hexat "$DEV" "$_at" 512) in
	*0000000000000000*) bios_blank=yes ;;
	*)                  bios_blank=no ;;
	esac
	say "  BIOS boot partition at LBA $_lba first byte: $bios_jump  blank: $bios_blank"
	if [ "$bios_jump" != 00 ] && [ "$bios_blank" = no ]; then
		pass 'the BIOS boot partition holds Limine second stage'
	else
		fail 'the BIOS boot partition is blank: limine wrote no second stage'
	fi
else
	fail 'there is no BIOS boot partition to hold Limine second stage'
fi

# Everything Limine reads has to be on the ESP, and that is the whole of what
# this section is about.  Limine's BIOS stage - the one that finds limine-bios.sys
# - has a FAT32 reader and an NTFS reader and no ext2/3/4 reader, so a boot chain
# on the ext4 root is a boot chain stage 2 cannot reach.  Placed there it fails
# with "Stage 3 file not found!" and the machine stops before the kernel, which is
# what this check is here to catch: every file below has to be readable off the
# FAT partition.
#
# The boot menu is checked for the two paths it names, so a menu that points at
# a file which is not there fails here rather than at the next boot.
#
# The ESP was unmounted at the UEFI check, so it goes back on.  Having FAT and
# ext4 mounted at once is not the problem it looks like; the point of the check is
# that a boot chain present on only one of them is a broken one, and either mount
# is what proves it.
mount -t vfat "$ESP" /mnt/esp || fail "could not mount the ESP $ESP a second time"
for _f in /limine-bios.sys /boot/limine-bios.sys /boot/bzImage \
	/boot/initramfs.img.gz /limine.conf /boot/limine.conf; do
	if [ -f "/mnt/esp$_f" ]; then
		pass "the boot chain has $_f on the ESP"
	else
		fail "the boot chain is missing $_f from the ESP"
	fi
done

# The menu has to name the two files, and name them where they are.
if [ -f /mnt/esp/limine.conf ]; then
	if grep -q 'kernel_path:[[:space:]]*boot():/boot/bzImage' /mnt/esp/limine.conf &&
	   grep -q 'module_path:[[:space:]]*boot():/boot/initramfs.img.gz' /mnt/esp/limine.conf; then
		pass 'the boot menu on the ESP names the kernel and the initramfs it has'
	else
		fail 'the boot menu on the ESP does not name the kernel and initramfs that are there'
		sed -n '1,20p' /mnt/esp/limine.conf >&2
	fi
	# `serial: yes` is the difference between a boot failure that says why and a
	# boot failure that is a blank screen.
	if grep -q '^serial:[[:space:]]*yes' /mnt/esp/limine.conf; then
		pass 'the boot menu turns the serial line on'
	else
		fail 'the boot menu does not say serial: yes, so a boot failure is silent'
	fi
else
	fail 'there is no boot menu on the ESP at all'
fi

# And the root filesystem must not be carrying a second copy of a 200 MB
# initramfs that nothing can read.  Not a correctness failure, but it is a fifth
# of the disk and it is worth knowing it is there.
if [ -f /mnt/root/boot/initramfs.img.gz ]; then
	fail 'the root filesystem holds an initramfs copy that Limine cannot read; it wastes disk'
else
	pass 'the root filesystem holds no unreadable copy of the initramfs'
fi
umount /mnt/esp
umount /mnt/root

# --- data mode --------------------------------------------------------------
#
# A separate set of checks rather than a branch inside the one above, because the
# two modes cannot both be verified against one disk: each erases it.  The host
# runs this script twice, once per mode, on a fresh image each time.
#
# What is being checked is the property that makes data mode worth having at all
# - the disk it makes is /var, and nothing else.  Every check here would have
# passed on the bug this replaces: it laid out a full boot chain, copied the
# entire system onto the disk, wrote a bootloader, printed
#
#   ok  the system is installed.
#
# and exited 0.  The disk it made *was* a working install, so nothing about
# reading that disk back could have shown the mode was wrong.  What shows it is
# counting the partitions and looking for a kernel.
if [ "$MODE" = data ]; then
	say ''
	say '--- data mode ---'

	# One partition.  Two would mean a boot partition crept back in, which is
	# the thing this layout exists to avoid.
	nparts=$(ls /dev/vda[0-9]* 2>/dev/null | wc -l)
	check 'the data disk has exactly one partition' "$nparts" '1'

	# No ESP and no BIOS boot partition, matched on the type GUIDs rather than
	# on a name or a position.  A disk that claims to boot and cannot is worse
	# than a disk that plainly does not, and a partition table promising
	# something the disk cannot deliver is the claim: an unformatted partition
	# carrying the ESP type GUID is exactly that.
	if [ -f /tmp/flx-gpt.txt ]; then
		if grep -qi 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' /tmp/flx-gpt.txt; then
			fail 'the data disk has an EFI system partition, so it claims to boot'
		else
			pass 'the data disk has no EFI system partition'
		fi
		if grep -qi '21686148-6449-6E6F-744E-656564454649' /tmp/flx-gpt.txt; then
			fail 'the data disk has a BIOS boot partition, so it claims to boot'
		else
			pass 'the data disk has no BIOS boot partition'
		fi
		if grep -qi '0FC63DAF-8483-4772-8E79-3D69D8477DE4' /tmp/flx-gpt.txt; then
			pass 'the data partition is a Linux filesystem partition'
		else
			fail 'no partition on the data disk is a Linux filesystem partition'
		fi
	else
		fail 'the partition table could not be read, so its contents are unknown'
	fi

	# The label is the whole contract with /init, which mounts a filesystem
	# called FREELINUX_VAR at /var.  Read back with blkid rather than believed,
	# because the bug this replaces also reported success.
	DPART=$(ls /dev/vda[0-9]* 2>/dev/null | head -1)
	if [ -z "$DPART" ]; then
		fail 'there is no data partition to read the label from'
	else
		say "  data partition: $DPART"
		dlabel=$(blkid -s LABEL -o value "$DPART" 2>/dev/null)
		check 'the data filesystem is labelled FREELINUX_VAR' \
			"$dlabel" 'FREELINUX_VAR'

		# And it has to be a filesystem this kernel can mount, or the label
		# is on something /init will fail to mount.
		if mkdir -p /mnt/data && mount -t ext4 "$DPART" /mnt/data 2>/dev/null; then
			pass 'the data filesystem mounts as ext4'
			# The four trees setup-lbu, setup-apkcache and the package
			# tools use.  An empty /var makes each of them take its
			# first-run path on a system that has already been installed.
			for d in lib/xpkg lib/lbu cache log; do
				if [ -d "/mnt/data/$d" ]; then
					pass "/var/$d exists on the data filesystem"
				else
					fail "/var/$d is missing from the data filesystem"
				fi
			done
			# Nothing installed.  This is the check that the mode does what
			# it says and is not a sys install under another name.
			if [ -e /mnt/data/sbin/init ] || [ -e /mnt/data/usr/bin/xsetup ]; then
				fail 'the data filesystem has a system on it; data mode installed something'
			else
				pass 'the data filesystem has no system on it'
			fi
			if [ -e /mnt/data/boot/bzImage ]; then
				fail 'the data filesystem has a kernel on it, so the disk claims to boot'
			else
				pass 'the data filesystem has no kernel on it'
			fi
			# A note for a human, which the installer claims to write.
			if [ -f /mnt/data/fstab.note ]; then
				pass 'the disk says what it is for'
			else
				fail 'there is no note on the disk saying what it is for'
			fi
			umount /mnt/data
		else
			fail 'the data filesystem does not mount as ext4'
		fi
	fi
fi

say ''
say "passed: $passed  failed: $failed"
printf 'summary passed=%d failed=%d\n' "$passed" "$failed"
say 'FLX-TEST-DONE'
[ "$failed" -eq 0 ]