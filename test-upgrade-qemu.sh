#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-upgrade-qemu.sh - install an older release, upgrade it with flxupgrade
# from the new ISO, and check that the machine and its data came through.
#
#   sh test-upgrade-qemu.sh [--uefi] OLD.iso [NEW.iso]
#
# Both ISOs must be SERIAL=1 builds (every release from 1.0.13 on is).  NEW
# defaults to out/freelinx-base-serial.iso.
#
#   1. boot OLD, install it with xsetup (alice, root, hostname xbox)
#   2. boot the installed disk, leave a file in /home and one in /etc
#   3. boot NEW with the disk attached, run flxupgrade -y
#   4. boot the disk: it is NEW's version, both files are there, alice and
#      root still log in with their passwords, the hostname is kept
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
UEFI=0
OLD= NEW=
for a do
	case $a in
	--uefi) UEFI=1 ;;
	*) if [ -z "$OLD" ]; then OLD=$a; else NEW=$a; fi ;;
	esac
done
NEW=${NEW:-$HERE/out/freelinx-base-serial.iso}
[ -f "${OLD:-}" ] || { echo 'usage: test-upgrade-qemu.sh [--uefi] OLD.iso [NEW.iso]' >&2; exit 2; }
[ -f "$NEW" ] || { echo "no ISO at $NEW" >&2; exit 2; }
ISO=$OLD
command -v qemu-system-x86_64 >/dev/null || { echo 'qemu-system-x86_64 not found' >&2; exit 2; }

# short: QEMU refuses unix socket paths of 108 bytes or more
W=$(mktemp -d /tmp/xsq.XXXXXX)
# KEEP=1 leaves the disk and the logs in $W for a look afterwards.
trap 'kill "$(cat "$W/pid" 2>/dev/null)" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "kept: $W" || rm -rf "$W"' EXIT
qemu-img create -f qcow2 "$W/disk.qcow2" 12G >/dev/null

FW=
if [ "$UEFI" = 1 ]; then
	# The firmware is OVMF, and it is installed under two names: Fedora and
	# openSUSE ship /usr/share/OVMF/OVMF_CODE_4M.fd, Debian and Ubuntu ship
	# /usr/share/ovmf/x64/OVMF_CODE.4m.fd.  Looking for one of them is a test
	# that passes on the machine it was written on and cannot run on the next.
	ovmf_code=
	ovmf_vars=
	for d in /usr/share/OVMF /usr/share/ovmf/x64 /usr/share/ovmf /usr/share/edk2-ovmf; do
		for pair in 'OVMF_CODE_4M.fd OVMF_VARS_4M.fd' 'OVMF_CODE.4m.fd OVMF_VARS.4m.fd' \
			'OVMF_CODE.fd OVMF_VARS.fd'; do
			# shellcheck disable=SC2086  # the pair is two words on purpose
			set -- $pair
			if [ -z "$ovmf_code" ] && [ -f "$d/$1" ] && [ -f "$d/$2" ]; then
				ovmf_code=$d/$1
				ovmf_vars=$d/$2
			fi
		done
	done
	[ -n "$ovmf_code" ] || { echo "no OVMF firmware found (looked in /usr/share/OVMF, /usr/share/ovmf)" >&2; exit 2; }
	cp "$ovmf_vars" "$W/vars.fd"
	FW="-machine q35 -drive if=pflash,format=raw,readonly=on,file=$ovmf_code -drive if=pflash,format=raw,file=$W/vars.fd"
fi
KVM=
[ -w /dev/kvm ] && KVM='-enable-kvm -cpu host'

vm() {
	rm -f "$W/sh.sock" "$W/console.log"
	# shellcheck disable=SC2086
	qemu-system-x86_64 $KVM -m 2048 -smp 2 $FW \
		-drive "file=$W/disk.qcow2,if=virtio,format=qcow2" "$@" \
		-vga std -display none -nic user,model=virtio-net-pci \
		-chardev "socket,id=s0,path=$W/sh.sock,server=on,wait=off,logfile=$W/console.log" \
		-serial chardev:s0 \
		-daemonize -pidfile "$W/pid" || exit 2
}
stop() { kill "$(cat "$W/pid")" 2>/dev/null; sleep 2; }

# serial PYTHON-ARGS... - talk to the guest's ttyS0 (see the helper below)
serial() { python3 "$W/serial.py" "$W/sh.sock" "$@"; }
cat >"$W/serial.py" <<'EOF'
import socket, sys, time
sock, mode = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(0.5)
def rd(wait, until=None):
    b = b""; t = time.time()
    while time.time() - t < wait:
        try: b += s.recv(65536)
        except socket.timeout: pass
        if until and until in b: break
    return b.decode(errors="replace")
if mode == "run":            # run CMD on the live root shell, wait for it
    cmd, wait = sys.argv[3], float(sys.argv[4])
    s.sendall(b"\r"); rd(1)
    # the marker is split in the command, so the echo of what was typed
    # cannot be mistaken for the command's end
    s.sendall(cmd.encode() + b"; echo __EN''D__$?\r")
    out = rd(wait, b"__END__")
    out += rd(1)
    print(out)
elif mode == "ping":         # does the live root shell answer?
    s.sendall(b"echo pi''ng-ok\r")
    print(rd(3, b"ping-ok\r\n"))
elif mode == "probe":        # what does an idle console answer with?
    s.sendall(b"\r"); print(rd(4))
elif mode == "login":        # log in as USER/PASS, run CMD, log out
    user, pw, cmd = sys.argv[3], sys.argv[4], sys.argv[5]
    s.sendall(b"\r"); rd(3, b"login:")
    s.sendall(user.encode() + b"\r"); rd(3, b"assword")
    s.sendall(pw.encode() + b"\r"); rd(4)
    s.sendall(cmd.encode() + b"; echo __EN''D__; exit\r")
    print(rd(20, b"__END__\r\n"))
EOF

pass=0; fail=0
check() {   # check NAME HAYSTACK NEEDLE
	if printf '%s' "$2" | grep -qF -- "$3"; then
		pass=$((pass + 1)); printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1)); printf '  FAIL %s (no [%s])\n' "$1" "$3"
	fi
}
wait_for() {   # wait_for PATTERN SECONDS - in the kernel console log
	n=0
	until grep -q "$1" "$W/console.log" 2>/dev/null; do
		n=$((n + 2)); [ "$n" -le "$2" ] || return 1; sleep 2
	done
}

live_up() {   # wait for the live root shell
	sleep 40
	n=0
	until serial ping 2>/dev/null | grep -q 'ping-ok'; do
		n=$((n + 5)); [ "$n" -le 240 ] || { echo '  FAIL the live medium did not boot'; exit 1; }
		sleep 5
	done
	sleep 10
}
xorriso -osirrox on -indev "$NEW" -extract /boot/limine/limine.conf "$W/new.conf" >/dev/null 2>&1
newver=$(sed -n 's/^interface_branding: FreeLinX \([0-9.]*\).*/\1/p' "$W/new.conf" | head -1)
[ -n "$newver" ] || { echo "cannot read the version of $NEW" >&2; exit 2; }

echo "== install the old release ($([ "$UEFI" = 1 ] && echo UEFI || echo BIOS)) =="
vm -cdrom "$OLD" -boot d
live_up
oldver=$(serial run 'sed -n "s/^VERSION_ID=//p" /etc/os-release' 10 | tr -d '"\r' | grep -E '^[0-9]+\.[0-9.]+$' | head -1)
echo "  old: ${oldver:-?}  new: ${newver:-?}"
# The user step asks for the password once in 1.0.13-1.0.15 and twice, with the
# doas question first, from 1.1.0; send what the old installer reads.
ANS=$(printf '%s\n' 1 xbox 1 r00tpw r00tpw 6 Asia/Baku n 1 '' y alice al1cepw y 2 y 2 2 yes | base64 -w0)
out=$(serial run "echo $ANS | base64 -d > /root/ans; xsetup < /root/ans > /root/xsetup.log 2>&1" 1200)
check 'the old release installs' "$out" '__END__0'
stop

echo '== use it =='
vm -boot c
wait_for 'login:' 240
out=$(serial login alice al1cepw 'echo keep-me > /home/alice/kept && sync && echo wrote-home')
check 'alice writes a file in /home' "$out" 'wrote-home'
out=$(serial login root r00tpw 'echo marker > /etc/flx-upgrade-marker && sync && echo wrote-etc')
check 'root writes a file in /etc' "$out" 'wrote-etc'
stop

echo '== upgrade it from the new live ISO =='
vm -cdrom "$NEW" -boot d
live_up
out=$(serial run 'flxupgrade -y' 900)
check 'flxupgrade finishes' "$out" '__END__0'
check 'flxupgrade names the new version' "$out" "-> $newver"
case $out in *warning*) fail=$((fail + 1)); echo '  FAIL flxupgrade warned:'; printf '%s\n' "$out" | grep warning ;; esac
stop

echo '== boot the upgraded disk, medium removed =='
vm -boot c
wait_for 'login:' 300 && pass=$((pass + 1)) && echo '  ok   the upgraded system reaches a login prompt' ||
	{ fail=$((fail + 1)); echo '  FAIL the upgraded system reaches a login prompt'; }
out=$(serial login alice al1cepw 'echo "who=$(id -un)"; cat /home/alice/kept')
check 'alice still logs in with her password' "$out" 'who=alice'
check "alice's file in /home is there" "$out" 'keep-me'
out=$(serial login root r00tpw 'echo "ver=$(sed -n "s/^VERSION_ID=//p" /etc/os-release | tr -d \")"; echo "host=$(hostname)"')
check "the system is $newver now" "$out" "ver=$newver"
check 'the hostname is kept' "$out" 'host=xbox'
out=$(serial login root r00tpw 'cat /etc/flx-upgrade-marker; ls /var/service')
check 'root still logs in with the root password' "$out" 'marker'
check 'sshd is still enabled' "$out" 'sshd'
stop

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
