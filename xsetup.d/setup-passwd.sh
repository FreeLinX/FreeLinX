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
need_cmd flxpasswd 'the base/flxpasswd port'

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
# The password goes in on stdin, not argv: anything in argv is visible to
# every process on the machine through ps.  -e is stdin mode, -r is the
# minimum length, which this step has already asked about.
if ! printf 'root:%s\n' "$pw" | flxpasswd -e -r; then
	die 'flxpasswd refused the password'
fi
pw=''
again=''

# flxpasswd refuses an empty hash, but verify anyway rather than trust it: a
# passwordless root account is a remote shell, and this is the last point
# before the installer reports success.
empty=$(awk -F: '$1 == "root" { print $2 }' /etc/shadow)
case $empty in
''|!*|'*')
	die "the root password is not set after flxpasswd (field is '$empty'). Refusing to continue."
	;;
esac

ok 'root password set'
