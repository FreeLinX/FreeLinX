#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-destructive.sh - run the commands an install to disk executes, against
# image files, with the binaries the installer itself uses (the image's, not
# the host's).
#
# test-setup-disk.sh covers the conversation: the geometry, the confirmations,
# the guards, and that a dry run touches nothing.  This covers what a real run
# does to bytes:
#
#   1. flxpart writes the four partitions /init expects (ESP, BIOS boot,
#      FLX_SYS, FLX_HOME) and reports them the way setup-disk reads them.
#   2. mkfs.fat -n FLX_BOOT and mkfs.ext4 -L FLX_SYS / -L FLX_HOME make what
#      their labels say.
#   3. the UUIDs come out of blkid the way setup-disk reads them, and the
#      /etc/flx-disk it writes is read back by /init's own flx_pin.
#   3b. /init mounts FLX_SYS by that pinned UUID and binds the seven trees
#      setup-disk seeds onto the image.
#   4. strip_live (from setup-disk itself) takes the live user out of passwd,
#      shadow, group and doas.conf, and leaves everything else.
#   4b. the /etc/motd and /etc/issue loop setup-disk runs before it writes the
#      image, so an installed machine does not read that nothing is kept.
#   5. the system image: cpio | xz --check=crc32, a check the kernel accepts.
#   6. the tar copy that seeds FLX_SYS keeps hard links and setuid bits.
#
# Mounting, limine bios-install and booting the result need root and a block
# device; test-xsetup-qemu.sh does a whole install in a VM.
#
# Run from anywhere:  sh test-destructive.sh

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# The tools of the tree base is built from (FreeLinX-desk).
ROOTFS=${ROOTFS:-$ROOT/src/rootfs}
SETUP_DISK=$HERE/xsetup.d/setup-disk.sh
LOADER=$ROOTFS/lib/ld-musl-x86_64.so.1

# Dynamic musl binaries run through the image's own loader; static ones as is.
tool() {
	_t=$ROOTFS/$1
	shift
	if readelf -l "$_t" 2>/dev/null | grep -q 'program interpreter'; then
		"$LOADER" --library-path "$ROOTFS/usr/lib:$ROOTFS/lib" "$_t" "$@"
	else
		"$_t" "$@"
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	shift
	for _l in "$@"; do printf '         %s\n' "$_l"; done
}
same() {
	if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want [$3]" "got  [$2]"; fi
}
section() { printf '== %s ==\n' "$1"; }

for t in sbin/flxpart sbin/mkfs.fat sbin/mkfs.ext4 sbin/blkid bin/cpio bin/tar usr/bin/xz; do
	[ -x "$ROOTFS/$t" ] || { printf 'error: %s/%s is missing\n' "$ROOTFS" "$t" >&2; exit 2; }
done
[ -x "$LOADER" ] || { printf 'error: no loader at %s\n' "$LOADER" >&2; exit 2; }

# a function out of setup-disk.sh, so the code under test is the code itself
extract() {
	sed -n "/^$1() {/,/^}/p" "$SETUP_DISK"
}

# --- 1. partitioning ------------------------------------------------------------
section 'flxpart writes the four partitions /init expects'
disk=$TMP/disk.img
truncate -s 16G "$disk"
layout=$(tool sbin/flxpart --esp-size 1024 --flx-sys-size 6553 --create-standard "$disk" 2>&1)
eval "$(extract part_indices)"
GUID_ESP=28732AC1-1FF8-D211-BA4B-00A0C93EC93B
GUID_BIOSBOOT=48616821-4964-6F6E-744E-656564454649
GUID_LINUX=AF3DC60F-8384-7247-8E79-3D69D8477DE4
same 'the ESP is partition 1' "$(part_indices "$GUID_ESP")" 1
same 'the BIOS boot partition is 2' "$(part_indices "$GUID_BIOSBOOT")" 2
same 'FLX_SYS and FLX_HOME are 3 and 4' "$(part_indices "$GUID_LINUX" | tr '\n' ' ')" '3 4 '
key() { printf '%s\n' "$layout" | sed -n "s/^FLX_PART$1_$2=//p"; }
same 'the ESP is 1 GiB' "$(key 1 SIZE_BYTES)" 1073741824
same 'BIOS boot is 1 MiB' "$(key 2 SIZE_BYTES)" 1048576
same 'FLX_SYS is the size asked for' "$(key 3 SIZE_MB)" 6553
lastu=$(printf '%s\n' "$layout" | sed -n 's/^FLX_DISK_LAST_USABLE=//p')
same 'FLX_HOME runs to the end of the disk' "$(key 4 LAST)" "$lastu"
if [ "$(key 2 FIRST)" -gt "$(key 1 LAST)" ] && [ "$(key 3 FIRST)" -gt "$(key 2 LAST)" ] &&
	[ "$(key 4 FIRST)" -gt "$(key 3 LAST)" ]; then
	ok 'the partitions are in order and do not overlap'
else
	no 'the partitions are in order and do not overlap' "$layout"
fi
if tool sbin/flxpart --show "$disk" 2>&1 | grep -q 'GPT Partition Table detected'; then
	ok 'flxpart --show reads back the table it wrote'
else
	no 'flxpart --show reads back the table it wrote'
fi
if command -v sgdisk >/dev/null 2>&1; then
	if sgdisk -v "$disk" 2>&1 | grep -q 'No problems found'; then
		ok 'sgdisk -v finds no problems in the table'
	else
		no 'sgdisk -v finds no problems in the table' "$(sgdisk -v "$disk" 2>&1 | head -3)"
	fi
fi

# --- 2. filesystems -------------------------------------------------------------
section 'the filesystems carry the labels /init and flxupgrade look for'
esp=$TMP/esp.img; sys=$TMP/sys.img; home=$TMP/home.img
truncate -s 64M "$esp"; truncate -s 64M "$sys"; truncate -s 64M "$home"
tool sbin/mkfs.fat -F 32 -n FLX_BOOT "$esp" >/dev/null 2>&1 || no 'mkfs.fat runs'
tool sbin/mkfs.ext4 -F -q -L FLX_SYS "$sys" 2>/dev/null || no 'mkfs.ext4 FLX_SYS runs'
tool sbin/mkfs.ext4 -F -q -L FLX_HOME "$home" 2>/dev/null || no 'mkfs.ext4 FLX_HOME runs'
b_esp=$(tool sbin/blkid "$esp" 2>/dev/null)
b_sys=$(tool sbin/blkid "$sys" 2>/dev/null)
b_home=$(tool sbin/blkid "$home" 2>/dev/null)
case $b_esp in *'LABEL="FLX_BOOT"'*'TYPE="vfat"'*) ok 'the ESP is FAT, labelled FLX_BOOT' ;;
	*) no 'the ESP is FAT, labelled FLX_BOOT' "$b_esp" ;; esac
case $b_sys in *'LABEL="FLX_SYS"'*'TYPE="ext4"'*) ok 'FLX_SYS is ext4' ;;
	*) no 'FLX_SYS is ext4' "$b_sys" ;; esac
case $b_home in *'LABEL="FLX_HOME"'*'TYPE="ext4"'*) ok 'FLX_HOME is ext4' ;;
	*) no 'FLX_HOME is ext4' "$b_home" ;; esac

# --- 3. UUIDs and /etc/flx-disk ------------------------------------------------
section 'the UUID pins, written by setup-disk and read by /init'
# setup-disk's part_uuid, fed the same blkid output
u_sys=$(printf '%s\n' "$b_sys" | grep -o ' UUID="[^"]*"' | cut -d'"' -f2)
u_home=$(printf '%s\n' "$b_home" | grep -o ' UUID="[^"]*"' | cut -d'"' -f2)
[ -n "$u_sys" ] && [ -n "$u_home" ] && ok 'both UUIDs are read' || no 'both UUIDs are read'
[ "$u_sys" != "$u_home" ] && ok 'the two UUIDs differ' || no 'the two UUIDs differ'
printf 'FLX_SYS_UUID=%s\nFLX_HOME_UUID=%s\n' "$u_sys" "$u_home" >"$TMP/flx-disk"
# /init's flx_pin, read out of /init rather than retyped here: a copy in the
# test would pass whether or not /init had the function.
INIT=${INIT:-$ROOTFS/init}
[ -r "$INIT" ] || { printf 'error: no /init at %s\n' "$INIT" >&2; exit 2; }
frominit() { sed -n "/^$1() {/,/^}/p" "$INIT"; }
grep -q '^flx_pin() {' "$INIT" && ok '/init has flx_pin' || no '/init has flx_pin'
eval "$(frominit flx_pin | sed 's#/etc/flx-disk#'"$TMP/flx-disk"'#')"
same '/init reads FLX_SYS_UUID back' "$(flx_pin FLX_SYS_UUID)" "$u_sys"
same '/init reads FLX_HOME_UUID back' "$(flx_pin FLX_HOME_UUID)" "$u_home"
grep -q 'FLX_SYS_UUID=%s\\nFLX_HOME_UUID=%s' "$SETUP_DISK" &&
	ok 'setup-disk writes flx-disk in that format' ||
	no 'setup-disk writes flx-disk in that format'

# --- 3b. /init puts the pinned partition in place --------------------------------
section '/init mounts FLX_SYS by the pinned UUID and binds the seven trees'
# These are the trees setup-disk seeds, so these and no others are what /init
# has to bind: a tree bound that was not seeded is an empty RAM directory
# wearing a disk's name, and a seeded tree left in RAM is the bug this file
# exists for.
grep -q 'for _d in usr etc var root bin sbin lib; do' "$INIT" &&
	ok '/init binds exactly the trees setup-disk seeds' ||
	no '/init binds exactly the trees setup-disk seeds'
grep -q '_sys_uuid=$(flx_pin FLX_SYS_UUID)' "$INIT" &&
	ok '/init reads the FLX_SYS pin' || no '/init reads the FLX_SYS pin'
grep -q 'flx_find UUID "\$_sys_uuid"' "$INIT" &&
	ok '/init matches on UUID, not on the label' ||
	no '/init matches on UUID, not on the label'
grep -q 'flx_find LABEL FLX_SYS' "$INIT" &&
	no '/init must not fall back to the FLX_SYS label' ||
	ok '/init has no FLX_SYS label fallback'
grep -q 'mount -o bind "/mnt/flx_sys/\$_d" "/\$_d"' "$INIT" &&
	ok '/init binds each tree with mount -o bind' ||
	no '/init binds each tree with mount -o bind'
# /var is already mounted by the FLX_SYS binds, so the FREELINUX_VAR scan has
# to come after them or it would be a second filesystem claiming one place.
sysline=$(grep -n 'flx_find UUID "\$_sys_uuid"' "$INIT" | cut -d: -f1)
varline=$(grep -n 'flx_find LABEL FREELINUX_VAR' "$INIT" | cut -d: -f1)
[ -n "$sysline" ] && [ -n "$varline" ] && [ "$sysline" -lt "$varline" ] &&
	ok 'FLX_SYS is mounted before the FREELINUX_VAR scan' ||
	no 'FLX_SYS is mounted before the FREELINUX_VAR scan'
# a pinned UUID no partition carries is the case that must be loud: the system
# then runs from RAM and loses everything, and nothing else would say so.
grep -q 'no partition carries the FLX_SYS UUID' "$INIT" &&
	ok '/init says so when the pinned UUID is absent' ||
	no '/init says so when the pinned UUID is absent'
grep -q 'did not mount; this system is running from RAM' "$INIT" &&
	ok '/init says so when the system partition will not mount' ||
	no '/init says so when the system partition will not mount'
# FLX_HOME is pinned too, and a medium with no pin has to still find it.
grep -q '_home_uuid=$(flx_pin FLX_HOME_UUID)' "$INIT" &&
	ok '/init reads the FLX_HOME pin' || no '/init reads the FLX_HOME pin'
grep -q 'flx_find LABEL FLX_HOME' "$INIT" &&
	ok 'a system with no pin still finds FLX_HOME by label' ||
	no 'a system with no pin still finds FLX_HOME by label'

# --- 4. the live user ------------------------------------------------------------
section 'strip_live takes the live user out, and nothing else'
eval "$(extract strip_live)"
r=$TMP/strip
mkdir -p "$r/etc"
printf '%s\n' 'root:x:0:0:root:/root:/bin/mksh' 'live:x:990:990:Live:/home/live:/bin/mksh' \
	'alice:x:1000:1000:alice:/home/alice:/bin/mksh' >"$r/etc/passwd"
printf '%s\n' 'root:$6$a:1::::::' 'live::1::::::' 'alice:$6$b:1::::::' >"$r/etc/shadow"
printf '%s\n' 'wheel:x:10:live,alice' 'live:x:990:' 'video:x:44:live' >"$r/etc/group"
printf '%s\n' 'permit persist :wheel' '# live ISO session user: administrator without a password (removed by the installer)' \
	'permit nopass keepenv live' >"$r/etc/doas.conf"
strip_live "$r"
same 'passwd keeps root and alice' "$(cut -d: -f1 "$r/etc/passwd" | tr '\n' ' ')" 'root alice '
same 'shadow keeps root and alice' "$(cut -d: -f1 "$r/etc/shadow" | tr '\n' ' ')" 'root alice '
same 'wheel keeps alice only' "$(grep '^wheel:' "$r/etc/group")" 'wheel:x:10:alice'
same 'the live group is gone' "$(grep -c '^live:' "$r/etc/group")" 0
same 'doas keeps the wheel rule only' "$(cat "$r/etc/doas.conf")" 'permit persist :wheel'

# --- 4b. the banner on an installed system -----------------------------------------
section 'setup-disk rewrites the banner it inherits from the medium'
# The banner is written by build-base.sh for a machine that keeps nothing, and
# it is the first thing on the screen of a machine that was just installed.  The
# loop is run here in a chroot holding nothing but /etc, so the code under test
# is setup-disk's own loop rather than a copy of it: it names /etc/motd and
# /etc/issue absolutely, and a chroot is the only way to let it write there.
CROOT=$TMP/croot
mkdir -p "$CROOT/etc" "$CROOT/bin"
for t in sh sed grep cat rm; do
	[ -x "$ROOTFS/bin/$t" ] || { printf 'error: %s/bin/%s is missing\n' "$ROOTFS" "$t" >&2; exit 2; }
	cp "$ROOTFS/bin/$t" "$CROOT/bin/$t"
done
# the banner as build-base.sh writes it
for f in motd issue; do
	{
		printf ' FreeLinX 1.0.12 base\n'
		printf '\n'
		printf ' Live system: nothing is kept until it is installed.\n'
		printf '\n'
		printf ' Install to disk: xsetup (as root).  Manuals: man <command>.\n'
	} >"$CROOT/etc/$f"
done
sed -n '/^for f in \/etc\/motd \/etc\/issue; do$/,/^done$/p' "$SETUP_DISK" >"$CROOT/rewrite.sh"
if [ ! -s "$CROOT/rewrite.sh" ]; then
	no 'setup-disk has no loop that rewrites /etc/motd and /etc/issue'
elif ! unshare -r -m true 2>/dev/null; then
	printf '  (no unshare -r -m: cannot run the rewrite, skipping)\n'
else
	printf '#!/bin/sh\ndie() { echo "die: $*" >&2; exit 1; }\n' >"$CROOT/rewrite.sh.2"
	cat "$CROOT/rewrite.sh" >>"$CROOT/rewrite.sh.2"
	if out=$(unshare -r -m chroot "$CROOT" /bin/sh /rewrite.sh.2 2>&1); then
		ok 'the rewrite runs and says nothing'
	else
		no 'the rewrite failed' "$out"
	fi
	same 'motd says the disk keeps things' \
		"$(sed -n 's/^\( Installed system:.*\)$/\1/p' "$CROOT/etc/motd")" \
		' Installed system: packages and settings are kept on this disk.'
	same 'issue says the same thing' \
		"$(sed -n 's/^\( Installed system:.*\)$/\1/p' "$CROOT/etc/issue")" \
		' Installed system: packages and settings are kept on this disk.'
	case $(cat "$CROOT/etc/motd") in
	*'Live system:'*) no 'motd still tells an installed system nothing is kept' ;;
	*) ok 'motd no longer tells an installed system that nothing is kept' ;;
	esac
	case $(cat "$CROOT/etc/motd") in
	*'Install to disk:'*) no 'motd still tells an installed system to install' ;;
	*) ok 'motd no longer tells an installed system to install' ;;
	esac
	ok 'the version line is left alone' \
		"$(sed -n 's/^\( FreeLinX .* base\)$/\1/p' "$CROOT/etc/motd")" ' FreeLinX 1.0.12 base'
	[ -f "$CROOT/etc/motd.new" ] && no 'the rewrite leaves motd.new behind' ||
		ok 'the rewrite leaves no temporary file behind'
	# and it must refuse rather than install a banner it did not understand
	printf ' something else entirely\n' >"$CROOT/etc/motd"
	printf ' something else entirely\n' >"$CROOT/etc/issue"
	if unshare -r -m chroot "$CROOT" /bin/sh /rewrite.sh.2 >"$TMP/rw.err" 2>&1; then
		no 'a banner it does not recognise is installed as if it were rewritten'
	else
		ok 'a banner it does not recognise stops the install'
	fi
	case $(cat "$TMP/rw.err") in
	*'/etc/motd'*) ok 'and it names the file whose banner it could not read' ;;
	*) no 'and it does not say which file stopped it' "$(cat "$TMP/rw.err")" ;;
	esac
fi

# --- 5. the system image ---------------------------------------------------------
section 'the system image is xz with a CRC32 check, with a cpio inside'
img=$TMP/tree
mkdir -p "$img/etc" "$img/bin"
printf 'x\n' >"$img/etc/flx-installed"
printf 'hello\n' >"$img/bin/hello"
( cd "$img" && find . -print0 | tool bin/cpio --null -o --format=newc 2>/dev/null |
	tool usr/bin/xz -3 -T0 --check=crc32 ) >"$TMP/initramfs.img.gz"
check=$(tool usr/bin/xz --robot -lv "$TMP/initramfs.img.gz" 2>/dev/null | awk -F'\t' '$1 == "stream" { print $9 }' | head -1)
same 'the xz check is CRC32 (the kernel rejects CRC64 and SHA-256)' "$check" CRC32
list=$(tool usr/bin/xz -dc "$TMP/initramfs.img.gz" | tool bin/cpio -t 2>/dev/null | sort | tr '\n' ' ')
case $list in *etc/flx-installed*bin/hello*|*bin/hello*etc/flx-installed*) ok 'the cpio holds the tree' ;;
	*) no 'the cpio holds the tree' "$list" ;; esac
grep -q "xz -3 -T0 --check=crc32" "$SETUP_DISK" && ok 'setup-disk packs with that command' ||
	no 'setup-disk packs with that command'
grep -q "not -path './home/\*'" "$SETUP_DISK" && ok 'the image leaves /home to FLX_HOME' ||
	no 'the image leaves /home to FLX_HOME'

# --- 6. seeding FLX_SYS -----------------------------------------------------------
section 'the tar copy that seeds FLX_SYS keeps hard links and setuid'
src=$TMP/src; dst=$TMP/dst
mkdir -p "$src/bin" "$dst"
printf 'a\n' >"$src/bin/one"
ln "$src/bin/one" "$src/bin/two"
printf 'su\n' >"$src/bin/su"
chmod 4755 "$src/bin/su"
( cd "$src" && tool bin/tar -cf - bin ) | ( cd "$dst" && tool bin/tar -xpf - )
i1=$(ls -i "$dst/bin/one" | awk '{print $1}')
i2=$(ls -i "$dst/bin/two" | awk '{print $1}')
same 'a hard link stays one file' "$i1" "$i2"
same 'setuid survives' "$(stat -c %a "$dst/bin/su")" 4755

# --- 7. what the real run must do around the writes ----------------------------
section 'setup-disk guards the disk while it writes'
grep -q ': >/run/flxinstall-active' "$SETUP_DISK" &&
	ok 'flxautomount is told to step aside before partitioning' ||
	no 'flxautomount is told to step aside before partitioning'
extract cleanup | grep -q '/run/flxinstall-active' &&
	ok 'the cleanup removes the flag' || no 'the cleanup removes the flag'
for m in /mnt/flx_home /mnt/flx_sys /mnt/flx_boot; do
	extract cleanup | grep -q "$m" && ok "the cleanup unmounts $m" || no "the cleanup unmounts $m"
done
grep -q 'limine bios-install "$dev" "$bios_i"' "$SETUP_DISK" &&
	ok 'limine bios-install is pointed at the BIOS boot partition' ||
	no 'limine bios-install is pointed at the BIOS boot partition'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
