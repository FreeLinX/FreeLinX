#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-proxy - set an HTTP proxy, or do without one.
#
# The value goes in three places, because three different things read it: the
# installer itself needs it now to reach the package index, xpkg needs it as
# environment when it runs, and anything the user starts later needs it from
# /etc/environment.  A URL with no scheme is completed as http://, which is
# what people type.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

mkdir -p /etc

if ! ask_yes 'Use an HTTP proxy for downloads' n; then
	# Set empty rather than leaving whatever was there: a stale proxy from
	# a previous install is a failure nobody can explain later.
	: >/etc/proxy.conf
	rm -f /etc/profile.d/proxy.sh
	ok 'no proxy configured'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
fi

host=$(ask 'Proxy host' '')
# An empty host after saying yes is a changed mind, not a failure.  It used to
# die, which ended the installer with steps 7 to 13 never run, and the operator
# was left at the shell having answered a question they thought they had skipped:
#
#     Use an HTTP proxy for downloads [[y/N]]:
#     Proxy host:
#     error: no proxy host given
#
# Treating it as "no proxy" is what they meant, and it leaves them where they
# were rather than at a prompt with no route forward.
if [ -z "$host" ]; then
	: >/etc/proxy.conf
	rm -f /etc/profile.d/proxy.sh
	ok 'no proxy configured'
	return 0
fi

port=$(ask 'Proxy port' '8080')

user=$(ask 'Proxy user (blank if none)' '')
pass=$(ask 'Proxy password (blank if none)' '')

case $host in
*://*) url=$host ;;
*)     url=http://$host ;;
esac

if [ -n "$port" ]; then
	case $url in
	*:*) : ;;
	*)  url=$url:$port ;;
	esac
fi

if [ -n "$user" ]; then
	if [ -n "$pass" ]; then
		url=$url
		auth=$user:$pass
	else
		auth=$user
	fi
fi

umask 077
printf '%s\n' "$url" >/etc/proxy.conf
if [ -n "${auth:-}" ]; then
	printf '%s\n' "$auth" >>/etc/proxy.conf
else
	: >/dev/null
fi
umask 022
chmod 600 /etc/proxy.conf

# /etc/environment is read by login shells, so this is what makes the proxy
# apply to a session the user starts later.
cat >/etc/profile.d/proxy.sh <<EOF
# Written by xsetup.
HTTP_PROXY=$url
HTTPS_PROXY=$url
http_proxy=$url
https_proxy=$url
export HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
EOF
chmod 644 /etc/profile.d/proxy.sh

ok "proxy set to $url"
