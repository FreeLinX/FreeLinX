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

need_cmd flxuseradd 'the base/flxuseradd port'
need_cmd flxpasswd 'the base/flxpasswd port'

info "creating $name"

# -m makes the home directory, -G adds to a group, -s sets the shell.
flxuseradd -m -G wheel -s /bin/sh "$name" ||
	die "flxuseradd could not create $name"

pw=$(ask "Password for $name" '')
if [ -z "$pw" ]; then
	warn "$name will have an empty password, which allows anyone who reaches"
	warn 'this machine to log in as them. Set one later with passwd if unsure.'
	# An empty field, not an empty hash.  Locking the account would be
	# quieter than what was just agreed, so flxpasswd is given -r and
	# asked to do exactly this: set an empty password.
	printf '%s:\n' "$name" | flxpasswd -e -r || :
	warn "$name has no password. Anyone who reaches this machine can log"
	warn 'in as them. Set one with: passwd '"$name"
else
	printf '%s:%s\n' "$name" "$pw" | flxpasswd -e -r ||
		die 'flxpasswd refused the password'
	pw=''
fi

if ask_yes 'Give this user sudo (as root)' y; then
	# doas is the other option, per the Alpine flow.  Checked first because
	# it is the one that can work on this image: sudo has no port here.
	if command -v doas >/dev/null 2>&1; then
		# doas reads a doas.conf, not a sudoers file, and it only
		# grants to a group it can find in /etc/group.
		{
			printf '# Written by xsetup.\n'
			printf 'permit persist :wheel\n'
		} >/etc/doas.conf
		chmod 644 /etc/doas.conf
		ok "$name can use doas: in wheel, and /etc/doas.conf permits it"
	elif command -v sudo >/dev/null 2>&1; then
		# The group is the point: flxuseradd already put $name in wheel
		# with -G, and that is what sudo reads.  So there is no sudoers
		# line to write here, and writing one anyway would be a second
		# place the policy lives.
		if grep -q '^%wheel' /etc/sudoers 2>/dev/null; then
			ok "$name can use sudo: in wheel, and %wheel is enabled"
		elif grep -q '^#.*%wheel' /etc/sudoers 2>/dev/null; then
			warn '%wheel is present in /etc/sudoers but commented out,'
			warn "so $name is in the group and still cannot sudo."
			warn 'Uncomment the %wheel line, or run: visudo'
		else
			warn "/etc/sudoers has no %wheel rule at all, so $name is in"
			warn 'the group and still cannot sudo. Add:'
			warn '    %wheel ALL=(ALL:ALL) ALL'
			warn 'and check it with visudo before trusting it.'
		fi
	else
		# $name is in wheel either way, so installing a sudo port later
		# makes this work with no further configuration.
		warn "neither doas nor sudo is installed, so $name cannot escalate"
		warn 'privileges yet. They are in the wheel group, so installing'
		warn 'either one is all that is needed: the membership is already'
		warn 'in place and this step will find the rule or write it.'
	fi
fi

ok "user $name created"
