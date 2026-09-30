#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-keymap - pick the console keyboard layout.
#
# The layout is written to /etc/conf.d/loadkmap.conf and applied to the
# running console.  Applying it needs a compiled keymap and something to load
# it with; without those the choice is still recorded, but the console keeps
# whatever layout it booted with, and that is said out loud rather than
# glossed over.

need_root

mkdir -p /etc/conf.d

keymap=$(choose 'Keyboard layout' \
	us 'us' \
	uk 'uk' \
	de 'de' \
	fr 'fr' \
	none 'leave the console as it booted')

if [ "$keymap" = none ]; then
	rm -f /etc/conf.d/loadkmap.conf
	ok 'console layout left alone'
	exit 0
fi

printf 'KEYMAP=%s\n' "$keymap" >/etc/conf.d/loadkmap.conf
ok "recorded $keymap in /etc/conf.d/loadkmap.conf"

# Now apply it, if there is a way to.
if command -v flxloadkmap >/dev/null 2>&1; then
	flxloadkmap "$keymap" && ok "loaded $keymap into the console" && exit 0
	warn "flxloadkmap could not load $keymap; the file is written though"
elif command -v loadkeys >/dev/null 2>&1; then
	loadkeys "$keymap" && ok "loaded $keymap into the console" && exit 0
	warn "loadkeys could not load $keymap; the file is written though"
else
	warn 'nothing here can load a keymap into the running console: neither'
	warn 'flxloadkmap nor loadkeys is installed. The choice is recorded, so a'
	warn 'boot-time loader will use it, but the console keeps the layout it'
	warn 'booted with until then. flxloadkmap comes from the'
	warn 'sysutils/flxloadkmap port and the keymap data from base/keymaps.'
fi
