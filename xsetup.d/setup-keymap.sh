#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-keymap - pick the keyboard layout.
#
# Written to /etc/conf.d/loadkmap.conf and used when a graphical session
# starts.
#
# It does not, and cannot, re-lay-out the running text console.  KDSETKEYMAP,
# the ioctl that used to allow it, was removed from Linux along with
# struct kbentry and the rest of the old kd.h console API; the console now
# carries one keymap compiled into the kernel, and there is no interface a
# program on a running system can use to change it.  NetBSD's kbdcomp and
# loadkeys are a pair for an interface that no longer exists here.
#
# So the layout is taken from XKB, which is what a framebuffer or X session
# actually reads, and this step says plainly what it did and did not do.  A
# step that appeared to change the console and did not would leave somebody
# typing a German layout on a US console with no way to tell why.

need_root

mkdir -p /etc/conf.d

# The values are XKB symbol-set names, which is the naming FreeLinX has:
# /usr/share/X11/xkb/symbols/{us,gb,de,fr}.  "uk" is a real keyboard but not
# a real XKB set -- it is "gb" -- so offering it would record a layout name
# that nothing could load.
keymap=$(choose 'Keyboard layout' \
	us 'us   US English' \
	gb 'gb   UK English' \
	de 'de   German' \
	fr 'fr   French' \
	none 'leave it as it is')

if [ "$keymap" = none ]; then
	rm -f /etc/conf.d/loadkmap.conf
	ok 'layout left alone'
	exit 0
fi

{
	printf '# Written by xsetup.\n'
	printf 'KEYMAP=%s\n' "$keymap"
} >/etc/conf.d/loadkmap.conf
ok "recorded $keymap in /etc/conf.d/loadkmap.conf"

# Check the set is actually there, rather than writing a preference nothing
# can satisfy.  A wrong name here is an X session that comes up in the wrong
# language, and it presents as X being broken.
xkbdir=${XKB_DIR:-/usr/share/X11/xkb}
if [ -d "$xkbdir/symbols/$keymap" ]; then
	ok "$xkbdir/symbols/$keymap is present"
else
	warn "there is no $xkbdir/symbols/$keymap, so a graphical session will"
	warn 'fall back to its default layout. The choice is recorded regardless.'
fi

say ''
say '  The text console keeps the layout it booted with: Linux removed the'
say '  ioctl that used to let a program change it. This setting is read by a'
say '  graphical session, which takes its layout from XKB.'
