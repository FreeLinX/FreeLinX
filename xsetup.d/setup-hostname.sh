#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-hostname - give the system a name.
#
# The name has to be in three places: set for this boot with the hostname
# command, in /etc/hostname so it survives a reboot, and in /etc/hosts so
# things that resolve by name do not stall on a DNS lookup.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

DEFAULT=$(cat /etc/hostname 2>/dev/null | head -1)
[ -n "$DEFAULT" ] || DEFAULT=freelinx

name=$(ask 'Hostname' "$DEFAULT")

# An empty label, or one with a slash in it, breaks every resolver that sees
# it, so it is refused here rather than three steps later.
case $name in
*[!A-Za-z0-9.-]*)
	die "'$name' is not a usable hostname: only letters, digits, dot and dash"
	;;
.*|-*|.*.*)
	die "'$name' is not a usable hostname: it cannot start or end with a dot or dash"
	;;
esac

info "setting the hostname to $name"
hostname "$name"

printf '%s\n' "$name" >/etc/hostname

# 127.0.0.1 has to stay on the first line: some software assumes the loopback
# resolves through it.
{
	printf '127.0.0.1\tlocalhost localhost.localdomain\n'
	printf '::1\t\tlocalhost localhost.localdomain\n'
	printf '127.0.1.1\t%s\n' "$name"
} >/etc/hosts

ok "hostname is $name"
