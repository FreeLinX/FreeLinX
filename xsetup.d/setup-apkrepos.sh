#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-apkrepos - point the package manager at a repository.
#
# FreeLinX uses xpkg, not apk, so the file is /etc/xpkg/repos.conf and the
# command is `xpkg repo add`.  The default repository is a public Hugging Face
# dataset, which needs no token: the index is signed and the signature is
# checked against /etc/xpkg/keys.  Reading it is anonymous.  Only publishing
# to it needs a token, and that is not something an installer does.

need_root
need_cmd xpkg 'xpkg' 'the xpkg port'

DEFAULT=https://huggingface.co/datasets/FreeLinX/packages/resolve/main

current=$(grep -v '^#' /etc/xpkg/repos.conf 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)
[ -n "$current" ] || current=$DEFAULT

info 'the repository is the FreeLinX package index:'
printf '  %s\n' "$DEFAULT"
printf 'it is signed, and needs no account or token.\n\n'

url=$(ask 'Repository URL (blank keeps the current one)' "$current")

if [ -z "$url" ]; then
	url=$current
fi

case $url in
http://*)
	# xpkg refuses to follow HTTPS down to HTTP, so offering one here would
	# only produce a confusing failure later.
	warn 'that is an http:// URL. Package downloads will not be verified.'
	if ! ask_yes 'Use it anyway' n; then
		die 'no repository URL was given'
	fi
	;;
esac

mkdir -p /etc/xpkg

# Written directly rather than through `xpkg repo add`, so re-running the step
# replaces the entry instead of appending a second copy of it.
{
	printf '# FreeLinX package repositories, one URL per line, highest priority first\n'
	printf '%s\n' "$url"
} >/etc/xpkg/repos.conf

ok "repositories file written to /etc/xpkg/repos.conf"

info 'refreshing the index'
if xpkg update; then
	ok 'index refreshed'
else
	# Not fatal: the installer can finish and the network can be fixed
	# afterwards, but pretending it worked would be worse than saying so.
	warn 'the index could not be refreshed. Packages will not install until'
	warn 'the network works. Check setup-interfaces and setup-proxy.'
fi
