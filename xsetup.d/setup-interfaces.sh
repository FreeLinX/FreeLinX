#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-interfaces - decide how each network interface gets an address.
#
# Wired interfaces are dhcp or static or off.  A wireless interface needs an
# SSID and a passphrase, which are written to a wpa_supplicant config with
# 0600 because the file holds a password in the clear.
#
# Interfaces are found by looking at what the kernel has actually created,
# not by guessing names: a name that is not there is a name that will never
# be configured.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root
need_cmd ifconfig 'the net/ifconfig port'

CONF=/etc/network/interfaces
CONF_D=/etc/network/interfaces.d
mkdir -p "$CONF_D"

# sysfs is the only place that lists interfaces the kernel really has.
# /sys/class/net/<name>/wireless is present only on wireless hardware.
list_ifaces() {
	for d in /sys/class/net/*; do
		[ -e "$d" ] || continue
		n=${d##*/}
		# lo is not a question to ask anybody.
		[ "$n" = lo ] && continue
		printf '%s\n' "$n"
	done
}

ifaces=$(list_ifaces)

if [ -z "$ifaces" ]; then
	warn 'no network interface was found.'
	warn 'The kernel may lack a driver, or this really is a machine with no'
	warn 'network hardware. /etc/network/interfaces has not been changed.'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
fi

info "interfaces found:"
printf '%s\n' "$ifaces" | sed 's/^/  /'

{
	printf '# FreeLinX network interfaces.  Written by xsetup.\n'
} >"$CONF"

printf '\n' >>"$CONF"

for n in $ifaces; do
	is_wireless=no
	[ -d "/sys/class/net/$n/wireless" ] && is_wireless=yes

	printf '\n# %s%s\n' "$n" \
		"$([ "$is_wireless" = yes ] && printf ' (wireless)' || true)" >>"$CONF"

	method=$(choose "How should $n be configured?" \
		dhcp 'automatic (DHCP)' \
		static 'a fixed address' \
		off 'leave it alone')

	case $method in
	dhcp)
		printf 'iface %s inet dhcp\n' "$n" >>"$CONF"
		ok "$n: dhcp"
		;;
	static)
		addr=$(ask "  address for $n" '')
		[ -n "$addr" ] || addr=$(ask "  address for $n, for example 192.168.1.10/24" '')
		# An address with no prefix length is ambiguous, and a wrong guess
		# is a network that silently does not work.
		case $addr in
		*/*) ;;
		*) addr=$addr/24 ;;
		esac

		gw=$(ask '  default gateway (blank for none)' '')
		ns=$(ask '  nameserver (blank for none)' '')

		printf 'iface %s inet static\n' "$n" >>"$CONF"
		printf '\taddress %s\n' "$addr" >>"$CONF"
		[ -n "$gw" ] && printf '\tgateway %s\n' "$gw" >>"$CONF"
		[ -n "$ns" ] && printf '\tdns-nameservers %s\n' "$ns" >>"$CONF"
		ok "$n: static $addr"
		;;
	off)
		printf '#iface %s inet dhcp\n' "$n" >>"$CONF"
		ok "$n: not configured"
		;;
	esac
done

# Wi-Fi, if there is any.  Kept out of the loop above because it needs a
# passphrase and because one supplicant config serves every wireless
# interface.
if printf '%s\n' "$ifaces" | while read -r n; do
	[ -d "/sys/class/net/$n/wireless" ] && printf 'yes\n'
done | grep -q yes; then

	printf '\n# wireless\n' >>"$CONF"

	if ask_yes 'Set up Wi-Fi now' y; then
		need_cmd wpa_supplicant 'the net/wpa_supplicant port'

		ssid=$(ask 'Wi-Fi network name (SSID)' '')
		if [ -n "$ssid" ]; then
			psk=$(ask 'Wi-Fi passphrase' '')
			# wpa_supplicant will not accept a WPA passphrase that is
			# too short, and it silently ignores an empty one, so both
			# are refused here where the message can explain.
			if [ -z "$psk" ]; then
				warn 'an open network needs no passphrase here'
			elif [ "${#psk}" -lt 8 ]; then
				die 'a WPA passphrase is at least 8 characters'
			fi

			mkdir -p /etc/wpa_supplicant
			umask 077
			{
				cat <<EOF
# Written by xsetup.  Holds a passphrase: mode 0600.
ctrl_interface=/var/run/wpa_supplicant
eapol_version=2
ap_scan=1

network={
	ssid="$ssid"
EOF
				# wpa_supplicant derives the 256-bit PSK itself, so the
				# derived form goes in rather than the plain text.
				# If it cannot be derived, the plain passphrase is
				# still accepted, quoted.
				if [ -n "$psk" ]; then
					hashed=$(wpa_passphrase "$ssid" "$psk" 2>/dev/null |
						sed -n 's/^[[:space:]]*psk=//p' | head -1)
					if [ -n "$hashed" ]; then
						printf '\tpsk=%s\n' "$hashed"
					else
						printf '\tpsk="%s"\n' "$psk"
					fi
				fi
				printf '}\n'
			} >/etc/wpa_supplicant/wpa_supplicant.conf
			umask 022
			chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
			ok "Wi-Fi configured for $ssid"
		fi
	fi
fi

if [ -d /var/service ]; then
	ln -sfn /etc/svc/dhcpcd /var/service/dhcpcd 2>/dev/null || :
	ln -sfn /etc/svc/wpa_supplicant /var/service/wpa_supplicant 2>/dev/null || :
fi

ok "written to $CONF"
