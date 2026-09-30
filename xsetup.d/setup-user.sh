#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-user - create a normal account to work in.
#
# A system you only ever use as root is a system where one typo is fatal, so
# this step exists to give the person installing it somewhere else to stand.
# The account goes in the wheel group, which is what sudo and doas look for.

need_root

if ! ask_yes 'Create a user account' y; then
	ok 'no user account created'
	exit 0
fi

name=$(ask 'Username' '')
case $name in
''|*[!a-z_]*[a-z_]*|*[!a-z0-9_-]*)
	die "'$name' is not a usable username: lower case letters, digits, dash and underscore"
	;;
esac

if awk -F: -v u="$name" '$1 == u { found = 1 } END { exit !found }' /etc/passwd; then
	die "the account $name already exists"
fi

need_cmd useradd 'the base/useradd port'
need_cmd chpasswd 'the base/chpasswd port'

info "creating $name"

# -m makes the home directory, -G adds to a group, -s sets the shell.
useradd -m -G wheel -s /bin/sh "$name" ||
	die "useradd could not create $name"

pw=$(ask "Password for $name" '')
if [ -z "$pw" ]; then
	warn "$name will have an empty password, which allows anyone who reaches"
	warn 'this machine to log in as them. Set one later with passwd if unsure.'
	# An empty field, not an empty hash: locking the account instead would
	# be quieter than what was just agreed.
	printf '%s:\n' "$name" | chpasswd || :
else
	printf '%s:%s\n' "$name" "$pw" | chpasswd || die 'chpasswd refused the password'
	pw=''
fi

if ask_yes 'Give this user sudo (as root)' y; then
	need_cmd sudo 'the security/sudo port'
	if command -v sudo >/dev/null 2>&1; then
		# The group is the point: adding the user to wheel is what sudo
		# reads, so no sudoers line is written by hand.
		if grep -q '^%wheel' /etc/sudoers 2>/dev/null; then
			ok "$name can use sudo"
		else
			usermod -aG wheel "$name" 2>/dev/null ||
				warn "could not add $name to the wheel group by hand"
			printf '%%wheel ALL=(ALL:ALL) ALL\n' >>/etc/sudoers
			ok "sudo enabled for the wheel group"
		fi
	else
		warn 'sudo is not installed, so the wheel group has nothing to read yet.'
		warn 'Install the security/sudo port and it will work without changes.'
	fi
fi

ok "user $name created"
