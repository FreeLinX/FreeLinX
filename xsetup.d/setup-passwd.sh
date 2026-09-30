#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-passwd - set the root password.
#
# The hash goes into /etc/shadow.  It is read, hashed and written back by the
# system's own passwd, not by an installer reimplementation: a hash written by
# anything other than the libc that will verify it is a coin toss.
#
# An empty root password is refused.  A base image with an empty root account
# is a remote shell for anyone who can reach it, and the refusal is here so
# that is not a thing somebody can do by pressing return too many times.

need_root
need_cmd chpasswd 'the base/chpasswd port'

[ -f /etc/shadow ] || die 'there is no /etc/shadow, so there is no root account to set'

while :; do
	pw=$(ask 'Root password (nothing is shown)' '')
	if [ -z "$pw" ]; then
		warn 'an empty root password is not allowed. It would make this'
		warn 'machine an unlocked shell for anyone who can reach it.'
		continue
	fi
	if [ "${#pw}" -lt 6 ]; then
		warn 'that is shorter than 6 characters.'
		if ask_yes 'Use it anyway' n; then
			break
		fi
		continue
	fi
	break
done

again=$(ask 'Root password again' '')
[ "$pw" = "$again" ] || die 'the two passwords did not match'

info 'setting the root password'
# chpasswd reads user:password on stdin.  The password is not on the command
# line, where any process could read it out of ps.
printf 'root:%s\n' "$pw" | chpasswd || die 'chpasswd refused the password'
pw=''
again=''

# A locked account is worse than a weak one to leave behind silently.
if awk -F: '$1 == "root" && $2 == "" { found = 1 } END { exit !found }' /etc/shadow; then
	die 'the root password is still empty after chpasswd. Refusing to continue.'
fi

ok 'root password set'
