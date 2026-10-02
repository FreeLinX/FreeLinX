#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-user - create a normal account to work in.
#
# A system you only ever use as root is a system where one typo is fatal, so
# this step exists to give the person installing it somewhere else to stand.
# The account goes in the wheel group, which is what sudo and doas look for.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

if ! ask_yes 'Create a user account' y; then
	ok 'no user account created'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
fi

name=$(ask 'Username' '')
# Upper case is accepted and folded to lower case, rather than refused.
#
# The rule used to allow only a-z0-9_- and die on anything else, so typing
# Kanan ended the installer with
#
#     error: 'Kanan' is not a usable username: lower case letters, digits,
#            dash and underscore
#
# Lower case is the right thing to *store* - /etc/passwd lookups are case
# sensitive, so a mixed-case name is a trap for whoever comes next - but it is
# not a reason to throw away what somebody typed and end the install over.  The
# name is folded and the fold is said out loud, so nobody ends up wondering why
# the account they typed is not the one they got.
case $name in
''|*[!a-zA-Z0-9_-]*)
	die "'$name' is not a usable username: letters, digits, dash and underscore"
	;;
esac

folded=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
if [ "$folded" != "$name" ]; then
	say "  $name -> $folded"
	name=$folded
fi

if awk -F: -v u="$name" '$1 == u { found = 1 } END { exit !found }' /etc/passwd; then
	die "the account $name already exists"
fi

need_cmd flxuseradd 'the base/flxuseradd port'
need_cmd flxpasswd 'the base/flxpasswd port'

info "creating $name"

# -d gives the home directory.  It used to be -m, which flxuseradd does not
# have, and the whole step failed on every install with its usage printed:
#
#     flxuseradd: unrecognized option: m
#     usage: flxuseradd -u NAME [-g GID] [-G GROUPS] [-d HOME] [-s SHELL]
#
# The usage is on two lines above the error and reads like a paragraph, so it
# scrolls past; what the operator saw was an account that was not created.
flxuseradd -d "/home/$name" -G wheel -s /bin/sh -u "$name" ||
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
