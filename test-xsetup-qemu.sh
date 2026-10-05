#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-xsetup-qemu.sh - a whole install with xsetup, in a VM, and the
# installed system checked from the inside.
#
#   sh test-xsetup-qemu.sh [--uefi] [ISO]
#
# ISO must be built with SERIAL=1 (sh build-base.sh): the test talks to the
# system on its serial port, ttyS0, where flxconsole gives the live medium a
# root shell and an installed system a login prompt.  The same port carries the
# kernel log, which QEMU also writes to console.log for wait_for.
# Default: out/freelinx-base-serial.iso.
#
#   1. boot the ISO with an empty 12 GiB disk
#   2. run xsetup and answer every one of its 13 steps, as a person would:
#      keymap, hostname, interfaces (dhcp), root password, time zone, no proxy,
#      ntpd, the default repository, a user with doas, openssh, install to the
#      disk, then the last two steps
#   3. boot the disk with the medium removed
#   4. log in as the user and as root, and check what the steps set: hostname,
#      time zone, the user's groups and shell, sshd running, the UUID pins,
#      the root partition as /, the framebuffer console
#   5. reboot, and check a file written in step 4 is still there
#
# Needs qemu-system-x86_64 (with KVM for speed) and, for --uefi, OVMF.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
UEFI=0
ISO=
for a do
	case $a in
	--uefi) UEFI=1 ;;
	*) ISO=$a ;;
	esac
done
ISO=${ISO:-$HERE/out/freelinx-base-serial.iso}
[ -f "$ISO" ] || { echo "no ISO at $ISO (build it with SERIAL=1)" >&2; exit 2; }
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

echo "== boot the live medium ($([ "$UEFI" = 1 ] && echo UEFI || echo BIOS)) =="
vm -cdrom "$ISO" -boot d
# Wait for the shell itself, which answers once the system is up.  Not
# before Limine has handed over: on UEFI the firmware connects the serial
# ports to Limine's menu, and a byte sent during the countdown stops it and
# opens the entry editor ("e" of "echo").
sleep 40
n=0
until serial ping 2>/dev/null | grep -q 'ping-ok'; do
	n=$((n + 5)); [ "$n" -le 240 ] || { echo 'the medium did not boot'; exit 1; }
	sleep 5
done
sleep 10

echo '== the live system =='
out=$(serial run 'fastfetch --pipe true 2>&1 | head -8' 30)
check 'fastfetch shows the FreeLinX wordmark' "$out" 'FreeLinX'
check 'fastfetch names the system' "$out" 'OS: FreeLinX'
# The live system runs from the medium (squashfs + a tmpfs overlay), not from a
# copy in RAM: / is the overlay and a fresh session uses well under 150 MB.
out=$(serial run 'echo "live""-root $(awk "\$2==\"/\"{print \$3}" /proc/mounts)"; free -m | awk "/^Mem/ { print \"used\" \"=\" \$3 }"' 15)
check 'the live root is an overlay on the medium' "$out" 'live-root overlay'
used=$(printf '%s\n' "$out" | sed -n 's/^used=\([0-9]*\).*/\1/p' | head -1)
if [ -n "$used" ] && [ "$used" -lt 150 ]; then
	pass=$((pass + 1)); echo "  ok   the live system uses ${used} MB of RAM"
else
	fail=$((fail + 1)); echo "  FAIL the live system uses ${used:-?} MB of RAM (150 at most)"
fi

echo '== xsetup, all 13 steps =='
# keymap us, hostname, eth0 dhcp, root password twice, region 6 (Asia) and
# its zone typed, no proxy, ntpd, the default repository, a user with a
# password and doas, openssh enabled, install (sys) to /dev/vda, yes.
ANS=$(printf '%s\n' 1 xbox 1 r00tpw r00tpw 6 Asia/Baku n 1 '' y alice y al1cepw al1cepw 2 y 2 2 yes | base64 -w0)
out=$(serial run "echo $ANS | base64 -d > /root/ans; xsetup < /root/ans > /root/xsetup.log 2>&1" 1200)
check 'xsetup finished' "$out" '__END__0'
log=$(serial run "sed 's/\\x1b\\[[0-9;]*m//g' /root/xsetup.log | grep -E '^  ok|error' | tr -s ' '" 20)
for s in setup-keymap setup-hostname setup-interfaces setup-passwd setup-timezone \
	setup-proxy setup-ntp setup-apkrepos setup-user setup-sshd setup-disk \
	setup-lbu setup-apkcache; do
	check "$s done" "$log" "ok $s"
done
check 'the disk is installed' "$log" 'FreeLinX is installed on /dev/vda'
stop

echo '== boot the disk, medium removed =='
vm -boot c
# /init's own messages go to /dev/console, which is the screen and not this
# serial line, so the boot is waited for on what this port does carry: the
# login prompt flxconsole puts on ttyS0 once runsvdir is up.
wait_for 'login:' 240 && pass=$((pass + 1)) &&
	echo '  ok   the installed system reaches a login prompt' ||
	{ fail=$((fail + 1)); echo '  FAIL the installed system reaches a login prompt'; }
sleep 15
# An installed system must ask: a shell here would make the root password
# that setup-passwd just set mean nothing.
out=$(serial probe)
check 'the console asks for a login' "$out" 'login:'
out=$(serial login alice al1cepw 'echo "who=$(id -un) sh=$0"; id; hostname; cat /etc/TZ; touch /home/alice/kept; ls /sys/firmware/efi >/dev/null 2>&1 && echo fw=UEFI || echo fw=BIOS')
check 'alice can log in' "$out" 'who=alice'
check "alice's shell is mksh" "$out" 'sh=-/bin/mksh'
check 'alice is in wheel' "$out" '(wheel)'
check 'the hostname is xbox' "$out" 'xbox'
check 'the time zone is Asia/Baku' "$out" 'Asia/Baku'
# The installed system runs from its disk: / is the ext4 root partition,
# mounted read-write after e2fsck, with no initramfs anywhere on the ESP.
# "root""-is" is split because the console echoes the command back: a needle
# spelled out in the command would find itself there.
# The marker is written and then synced: stop(1) is a SIGTERM to QEMU, which
# QEMU answers by exiting, not by asking the guest to power down.
out=$(serial login root r00tpw 'echo "root""-is $(awk "\$2==\"/\"{print \$3, substr(\$4,1,2)}" /proc/mounts)"; echo "tmp""-is $(awk "\$2==\"/tmp\"{print \$3}" /proc/mounts)"; echo "home""-is $(awk "\$2==\"/home\"{print \$1}" /proc/mounts)"; cat /proc/cmdline; echo "who=$(id -un)"; ls /var/service; tail -2 /var/log/sshd.log; cat /etc/flx-disk; grep -c UUID= /etc/fstab; cat /sys/class/vtconsole/vtcon1/name; grep -c "^live:" /etc/passwd; echo persisted > /etc/flx-test-marker; sync; cat /etc/flx-test-marker; for f in null tty console kmsg; do echo "$f $(ls -l /dev/$f | cut -c1-10)"; done; grep -c "^ Installed'' system:" /etc/motd /etc/issue')
check '/ is the ext4 root partition, read-write' "$out" 'root-is ext4 rw'
check '/tmp is in RAM' "$out" 'tmp-is tmpfs'
check '/home is its own partition' "$out" 'home-is /dev/vda4'
check 'the kernel found / by PARTUUID' "$out" 'root=PARTUUID='
check 'root can log in' "$out" 'who=root'
check 'sshd is a service' "$out" 'sshd'
check 'sshd is listening' "$out" 'Server listening on'
check 'ntpd is a service' "$out" 'ntpd'
check 'the partitions are pinned' "$out" 'FLX_ROOT_UUID='
check 'the console is a framebuffer' "$out" 'frame buffer device'

# The modes mdevd hands the nodes the kernel already made.  devtmpfs creates
# these before mdevd starts, and mdevd's own default for a node no rule names
# is 0660 root:root, so a rule that is missing or that never matches leaves
# /dev/null unwritable for a normal user and the login dies on the first
# redirect in /etc/profile.  cut -c1-10 is the mode on its own, and each line
# is named by the device it came from, so the answer cannot be found in the
# command the console echoed back.
check '/dev/null is 0666' "$out" 'null crw-rw-rw-'
check '/dev/tty is 0666' "$out" 'tty crw-rw-rw-'
check '/dev/console is 0600' "$out" 'console crw-------'
check '/dev/kmsg is 0660' "$out" 'kmsg crw-rw----'

# The banner is rewritten before the system is copied, so a machine that has
# just been installed must not go on reading "Live system: nothing is kept
# until it is installed" - the opposite of the truth, and the first thing on
# the screen.  Both files, because sshd shows /etc/issue before the password
# prompt.  The needle is spelled "Installed'' system:" in the command so that
# the console's echo of the command cannot be what satisfies the check.
case $out in
*'/etc/motd:1'*) pass=$((pass + 1)); echo '  ok   the banner says this system is installed' ;;
*) fail=$((fail + 1)); echo '  FAIL the banner still calls an installed system a live one' ;;
esac
case $out in
*'/etc/issue:1'*) pass=$((pass + 1)); echo '  ok   the sshd pre-login banner says it too' ;;
*) fail=$((fail + 1)); echo '  FAIL /etc/issue still calls an installed system a live one' ;;
esac
stop

echo '== reboot: what was written stays =='
vm -boot c
wait_for 'login:' 240
sleep 15
out=$(serial login alice al1cepw 'ls /home/alice/kept && echo home-kept; cat /etc/flx-test-marker')
check "alice's file in /home survived the reboot" "$out" 'home-kept'
check 'a file written to /etc survived the reboot' "$out" 'persisted'
stop

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
