#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# mkrootfs.sh - make the base rootfs: the desktop's system, without the desktop.
#
#   sh scripts/mkrootfs.sh -o STAGE
#
# Base is built from the same tree the desktop release is built from
# (FreeLinX-desk: src/rootfs + kernel/bzImage + the stack packages), because
# that tree is the one that is kept current and passes check-nognu.  The old
# src/rootfs is not: Linux 6.6, GCC-built tools, GNU ncurses linked in.
#
# The desktop is taken out by package, not by search:
#
#   1. copy the desktop rootfs into STAGE (never edit the source tree)
#   2. register every stack package in STAGE's xpkg database, as the desktop
#      image build does
#   3. xpkg remove every package not in KEEP - each one takes its own files
#   4. delete the desktop files that no package owns (UNOWNED, below)
#   5. turn the greetd service into a plain console login
#   6. refuse the result if any ELF needs a library that is gone, or if
#      check-nognu finds GNU code in it
#
# Two sources (step 1b says how they differ):
#
#   FreeLinX/src   (default) src/rootfs, already a console system, plus the
#                  KEEP packages installed by name from the signed package
#                  repository - the same one installed systems update from -
#                  so the image has a package database and needs nothing that
#                  is not in git or in that repository.
#   FreeLinX-desk  BASE_FROM_DESKTOP=1: the desktop rootfs and its local stack
#                  packages, desktop removed.  Needs a built Desktop-test.
#
# Environment:
#   FLXSRC    the FreeLinX/src checkout    (default: ../src)
#   DESK      the FreeLinX-desk checkout   (default: ../Desktop-test)
#   REPO      package repository URL       (default: the FreeLinX repository)
#   XPKG      a host xpkg command          (default: the desk's, or xpkg on PATH)
#   SYSROOT   musl sysroot, for tcc's crt*.o and libc headers.  Either layout
#             the toolchain makes: $SYSROOT/{include,lib} or a /usr-shaped
#             $SYSROOT/usr/{include,lib}.  Default: the desktop stack's, else
#             ~/freelinx/toolchain/x86_64-linux-musl as toolchain/README.md
#             builds it.
#   MUSL_SRC  configured musl source tree, for tcc's libc headers.  Optional:
#             without one the sysroot's own headers are used, which are the
#             same files.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DESK=${DESK:-$ROOT/Desktop-test}
FLXSRC=${FLXSRC:-$ROOT/src}
REPO=${REPO:-https://huggingface.co/datasets/FreeLinX/packages/resolve/main}

STAGE=
while [ $# -gt 0 ]; do
	case $1 in
	-o) STAGE=$2; shift ;;
	*) printf 'usage: %s -o STAGE\n' "${0##*/}" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$STAGE" ] || { printf 'usage: %s -o STAGE\n' "${0##*/}" >&2; exit 2; }

die() { printf 'mkrootfs: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

if [ "${BASE_FROM_DESKTOP:-0}" = 1 ]; then
	SRC_GIT=$DESK
else
	SRC_GIT=$FLXSRC
fi
SRC=$SRC_GIT/src/rootfs
[ "$SRC_GIT" = "$FLXSRC" ] && SRC=$FLXSRC/rootfs
PKGS=$DESK/stack/work/pkgs

# The musl sysroot: tcc needs musl's headers, the kernel UAPI headers and
# musl's start files, and the toolchain checkout is the only thing that has
# them.  Two layouts are real and the toolchain README says which one it makes:
# it configures musl with --prefix=$SYSROOT, which puts the headers in
# $SYSROOT/include and the objects in $SYSROOT/lib, while the desktop stack's
# sysroot is a /usr-shaped tree with usr/include and usr/lib.  Hard-coding the
# second is why a base built from this repository failed with "cannot stat
# .../usr/include/linux" on every machine that had followed the toolchain's own
# instructions.
if [ -z "${SYSROOT:-}" ]; then
	# toolchain/README.md builds into ~/freelinix (sic); ~/freelinx is accepted too
	for c in "$DESK/stack/work/sysroot" "$ROOT/toolchain/x86_64-linux-musl" \
		"$HOME/freelinix/toolchain/x86_64-linux-musl" \
		"$HOME/freelinx/toolchain/x86_64-linux-musl"; do
		if [ -d "$c/usr/include" ] || [ -d "$c/include" ]; then
			SYSROOT=$c
			break
		fi
	done
fi
[ -n "${SYSROOT:-}" ] ||
	die 'no musl sysroot: set SYSROOT to a built FreeLinX toolchain (toolchain/README.md builds one into ~/freelinix/toolchain/x86_64-linux-musl)'
if [ -d "$SYSROOT/usr/include" ] || [ -d "$SYSROOT/usr/lib" ]; then
	SYSROOT_PREFIX=/usr
else
	SYSROOT_PREFIX=
fi
SYS_INC=$SYSROOT$SYSROOT_PREFIX/include
SYS_LIB=$SYSROOT$SYSROOT_PREFIX/lib
# The strict checker, kept in this repository: besides GNU libraries in
# DT_NEEDED it finds GNU code linked in statically (ncurses, readline) by its
# fingerprints, which a DT_NEEDED-only check passes.
CHECK_NOGNU=$HERE/check-nognu.sh

# The host xpkg.  The desk's is a dynamic musl binary run through musl-run;
# anything else that runs here will do (a static xpkg, say).
if [ -z "${XPKG:-}" ]; then
	if [ -x "$DESK/stack/work/bin/musl-run" ] && [ -x "$SYSROOT$SYSROOT_PREFIX/bin/xpkg" ]; then
		XPKG="$DESK/stack/work/bin/musl-run $SYSROOT$SYSROOT_PREFIX/bin/xpkg"
	elif command -v xpkg >/dev/null 2>&1; then
		XPKG=xpkg
	else
		# None here: take one from the repository, signature-checked.
		say "==> fetching a host xpkg from the package repository"
		XPKG=$(sh "$HERE/host-xpkg.sh" "$STAGE.hostxpkg" "$REPO") ||
			die 'no host xpkg, and none could be fetched (set XPKG to one)'
	fi
fi

[ -d "$SRC/usr/bin" ] || die "no rootfs at $SRC"
[ -f "$CHECK_NOGNU" ] || die "no check-nognu.sh at $CHECK_NOGNU"
if [ "${BASE_FROM_DESKTOP:-0}" = 1 ]; then
	ls "$PKGS"/*.xpkg >/dev/null 2>&1 || die "no packages in $PKGS"
fi

# The rootfs is copied from the working tree, so uncommitted work would ship
# in an image no commit describes.  ALLOW_DIRTY=1 for a test build.
if [ "${ALLOW_DIRTY:-0}" != 1 ] && git -C "$SRC_GIT" rev-parse >/dev/null 2>&1; then
	dirty=$(git -C "$SRC_GIT" status --porcelain -- "${SRC#"$SRC_GIT"/}")
	[ -z "$dirty" ] || die "uncommitted changes in $SRC (ALLOW_DIRTY=1 to build anyway):
$dirty"
	say "==> source tree $SRC_GIT at $(git -C "$SRC_GIT" rev-parse --short HEAD)"
fi

# shellcheck disable=SC2086  # XPKG may be a command with arguments
xpkg() { NO_COLOR=1 $XPKG --root "$STAGE" "$@"; }

# The packages base keeps.  Everything else in the stack is the desktop.
KEEP='
ca-certificates dbus expat flxnet libcxx libedit libelf libffi libmd libnl
libudev-zero libxml2 linux linux-firmware musl netbsd-curses nnn openssl pcre2
sqlite toybox tzdata wpa_supplicant xpkg zlib
'

# Desktop files that are in the desktop rootfs but in no package: configs,
# themes, launchers and a few apps that were copied in by hand.  Paths are
# relative to the rootfs; a missing one is skipped.
UNOWNED='
bin/foot bin/sxiv bin/xcalc bin/libnl bin/libX11-1.8.10 bin/libXau-1.0.11
bin/libxcb-1.17.0 bin/libXcursor-1.2.2 bin/libXdmcp-1.1.4 bin/libXext-1.3.6
bin/libXfixes-6.0.1 bin/libXft-2.3.8 bin/libXinerama-1.1.5 bin/libXrandr-1.5.4
bin/libXrender-0.9.11 bin/xcb-proto-1.17.0 bin/xorgproto-2024.1 bin/xtrans-1.6.0
usr/bin/dunst usr/bin/feh usr/bin/flx3dtest usr/bin/flxbg usr/bin/flxbrowser
usr/bin/flx-session usr/bin/flxupdates usr/bin/geany usr/bin/greetd
usr/bin/agreety usr/bin/tuigreet usr/bin/links usr/bin/mupdf usr/bin/pcmanfm
usr/bin/picom usr/bin/rxvt usr/bin/uxterm usr/bin/xterm usr/bin/x-www-browser
usr/lib/libatk-1.0.so.0.23809.1 usr/lib/openbox lib/python3.12
etc/X11 etc/xdg etc/greetd etc/fonts
root/.Xdefaults root/.config/openbox root/.themes home/live/.config
usr/share/X11 usr/share/icons usr/share/fonts usr/share/pixmaps
usr/share/applications usr/share/themes usr/share/backgrounds
usr/share/glib-2.0 usr/share/xsessions
var/lib/xkb var/lib/bluetooth var/lib/greetd
var/service/greetd var/service/bluetoothd var/service/flxupdates
'

# --- 1. copy -----------------------------------------------------------------
say "==> copying $SRC"
rm -rf "$STAGE"
mkdir -p "$STAGE"
(cd "$SRC" && tar -cf - .) | (cd "$STAGE" && tar -xf -)

# --- 1b. is this source tree already a base system? ---------------------------
# Everything below was written for one answer: the source is the desktop's
# rootfs, and base is that with the desktop taken out.  So it installs every
# stack package and then removes the hundred the desktop needs and base does
# not, which leaves a package database describing what is there.
#
# src/rootfs is not the desktop's rootfs.  It has already been through that: no
# Xorg, no openbox, no libX11, no feh, no dzen2.  Installing the desktop packages
# onto it has nothing to install them onto and stops on the first one:
#
#     error: dzen2 needs libXft (not installed, and no repository to fetch it from)
#
# and the packages that would build the database - dbus, openssl, musl, xpkg,
# netbsd-curses and twenty more - are produced by the desktop stack into
# stack/work/pkgs, which is a build output of a tree that is not this
# repository.  Ten of the twenty-five have no recipe in ports either.
#
# Those twenty-five are published, though: publish-repo.sh put the same
# archives in the signed package repository, and that is where they are taken
# from (step 2), by name.  The desktop packages are never installed, so there is
# nothing to remove.
#
# Set BASE_FROM_DESKTOP=1 to build from a built Desktop-test instead.
if [ "${BASE_FROM_DESKTOP:-0}" = 1 ]; then
	SRC_IS_BASE=no
else
	SRC_IS_BASE=yes
	if [ -e "$SRC/usr/bin/Xorg" ] || [ -e "$SRC/usr/lib/libX11.so" ]; then
		die "$SRC has a desktop in it (Xorg, libX11); BASE_FROM_DESKTOP=1 is for that"
	fi
fi

# --- 1c. desktop source: the console and account tools from FreeLinX/src -----
# The desktop tree has none of these - its consoles are greetd and a serial
# shell.  flxconsole puts a shell on the live medium's consoles and a login on
# an installed system's; setup-passwd and setup-user need flxpasswd and
# flxuseradd.
if [ "$SRC_IS_BASE" = no ]; then
	for f in sbin/flxconsole bin/flxpasswd bin/flxuseradd var/service/shell/run; do
		if [ "${ALLOW_DIRTY:-0}" != 1 ] && git -C "$FLXSRC" rev-parse >/dev/null 2>&1; then
			[ -z "$(git -C "$FLXSRC" status --porcelain -- "rootfs/$f")" ] ||
				die "uncommitted changes in $FLXSRC/rootfs/$f (ALLOW_DIRTY=1 to build anyway)"
		fi
		[ -f "$FLXSRC/rootfs/$f" ] || die "no $f in $FLXSRC/rootfs (FLXSRC= the FreeLinX/src checkout)"
		cp -p "$FLXSRC/rootfs/$f" "$STAGE/$f"
	done
fi
# An flxconsole that gives an installed system a shell makes the root password
# xsetup sets mean nothing: v1.0.11.1 shipped one.
grep -q flx-installed "$STAGE/sbin/flxconsole" ||
	die 'flxconsole gives an installed system a shell instead of a login'

# The repository's signing key and address.  xpkg refuses a repository whose
# index it cannot verify, so an image without the key installs nothing.
mkdir -p "$STAGE/etc/xpkg/keys"
cp "$HERE/../keys/freelinx.pub" "$STAGE/etc/xpkg/keys/freelinx.pub"
[ -s "$STAGE/etc/xpkg/repos.conf" ] || printf '%s\n' "$REPO" >"$STAGE/etc/xpkg/repos.conf"

# --- 2. register -------------------------------------------------------------
if [ "$SRC_IS_BASE" = yes ]; then
	# The KEEP packages, by name from the signed repository: the libraries
	# and services base is made of get a package database that describes
	# them, so `xpkg upgrade` and anything installed later see them as
	# installed instead of trying to put a second copy on top.  These are the
	# same archives the desktop stack produced, published by publish-repo.sh,
	# so nothing here depends on a Desktop-test being built on this machine.
	# -f: the src rootfs already carries some of these files; the package's
	# copy wins and is registered.
	say "==> installing $(echo $KEEP | wc -w) packages from $REPO"
	rm -rf "$STAGE.cfg"
	mkdir -p "$STAGE.cfg/keys"
	cp "$STAGE/etc/xpkg/keys/freelinx.pub" "$STAGE.cfg/keys/"
	printf '%s\n' "$REPO" >"$STAGE.cfg/repos.conf"
	# musl-dev: musl's and the kernel's headers and crt*.o, for tcc (4c below)
	XPKG_CONFIG_DIR=$STAGE.cfg xpkg --quiet --no-scripts -f install $KEEP musl-dev \
		>"$STAGE.register.log" 2>&1 || {
		tail -20 "$STAGE.register.log" >&2
		die 'installing the packages from the repository failed'
	}
	rm -rf "$STAGE.cfg"
	# One kernel's modules: the linux package's.  The tree carries modules of
	# its own (6.6.21) that no kernel in this image can load.
	kv=$(xpkg files linux | sed -n 's#^/lib/modules/\([^/]*\)/.*#\1#p' | head -1)
	[ -n "$kv" ] || die 'the linux package installed no modules'
	for d in "$STAGE"/lib/modules/*; do
		[ "${d##*/}" = "$kv" ] || rm -rf "$d"
	done
else
	# Every stack package, so that there is a database to remove against.
	set -- $(ls "$PKGS"/*.xpkg | grep -v -E '/(ncurses|netsurf)-[0-9][^/]*\.xpkg$')
	say "==> registering $# packages"
	xpkg --quiet --no-scripts install "$@" >"$STAGE.register.log" 2>&1 || {
		tail -20 "$STAGE.register.log" >&2
		die 'registering packages failed'
	}
fi
find "$STAGE/etc" -name '*.xpkgnew' -type f -delete

# --- 3. remove the desktop packages ------------------------------------------
# Nothing to remove: step 2 installed only what KEEP names, and anything the
# trimmed rootfs still carries that no package owns is dealt with by UNOWNED
# below.  The loop is kept because it is what says so out loud if that stops
# being true - a package installed here that KEEP does not name is a bug in KEEP.
drop=
if [ "$SRC_IS_BASE" = yes ]; then
	# There is no database and nothing was installed, so there is nothing to
	# remove: the source tree is the answer.  The unowned desktop files in
	# step 4 are still swept, because those are files no package ever owned.
	say '==> nothing to remove: the source has no desktop packages in it'
	for p in $(echo $KEEP); do
		xpkg info "$p" >/dev/null 2>&1 || die "kept package $p is not installed"
	done
else
	for p in $(xpkg list | awk '{ print $1 }'); do
		case " $(echo $KEEP) " in
		*" $p "*) ;;
		*) drop="$drop $p" ;;
		esac
	done
	if [ -n "$drop" ]; then
		say "==> removing $(echo $drop | wc -w) packages KEEP does not name"
		# -f: removing a library and everything that needs it in one call is the
		# point.
		xpkg --quiet --no-scripts -f remove $drop >"$STAGE.remove.log" 2>&1 || {
			tail -20 "$STAGE.remove.log" >&2
			die 'removing the desktop packages failed'
		}
	fi
	for p in $(echo $KEEP); do
		xpkg info "$p" >/dev/null 2>&1 || die "kept package $p is not installed"
	done
fi

# --- 4. unowned desktop files ------------------------------------------------
say '==> removing unowned desktop files'
# /usr/sbin/xsetup is the desktop's installer wrapper.  It looks for the
# installer on the medium it booted from and says "medium is not in the drive"
# when there is none, so on base it gets in front of base's own installer and
# stops it installing anything at all.  Base's installer is xsetup, run from
# the shell, and it reads the medium itself.
if [ -e "$STAGE/usr/sbin/xsetup" ]; then
	say '    removing the desktop installer wrapper /usr/sbin/xsetup'
	rm -f "$STAGE/usr/sbin/xsetup"
fi
for p in $UNOWNED; do
	if [ -e "$STAGE/$p" ] || [ -L "$STAGE/$p" ]; then
		rm -rf "${STAGE:?}/$p"
	fi
done
# licenses of packages that are gone
if [ "$SRC_IS_BASE" = yes ]; then
	# No database, so `xpkg info` fails for every name and this would delete
	# every licence in the tree - including the ones belonging to the packages
	# that are installed.  The packages are all still here, so their licences
	# are too.
	:
else
	for d in "$STAGE"/usr/share/licenses/*; do
		[ -d "$d" ] || continue
		n=${d##*/}
		case $n in SOURCES|netbsd|musl-fts|linux-pam|llvm-rt|elftoolchain) continue ;; esac
		xpkg info "$n" >/dev/null 2>&1 || rm -rf "$d"
	done
fi
rm -rf "$STAGE/var/cache/xpkg" "$STAGE/var/lib/xpkg/lock"
rm -f "$STAGE/etc/flx-desktop"

# --- 4b. what a console system needs that the desktop did not ship ----------
# All non-GNU ports packages (ISC, BSD, GPL-2 Linux tools); check-nognu below
# checks them like everything else.
#   mandoc    the man formatter; /usr/bin/man was a desktop help script
#   less      pager (BSD-2-Clause option of its dual licence)
#   iproute2  ip
#   lsof
#   stty      xsetup turns echo off with it while a password is typed
#   mksh      the interactive shell: /bin/sh (NetBSD sh) is built without
#             libedit, so arrows printed ^[[A and there was no history
ADD='mandoc less iproute2 lsof mksh stty'
PORTS_PKGS=${PORTS_PKGS:-$ROOT/ports/packages}
rm -f "$STAGE/usr/bin/man"
set --
for p in $ADD; do
	f=$(ls "$PORTS_PKGS/$p"-[0-9A-Z]*.xpkg 2>/dev/null | sort -V | tail -1)
	[ -n "$f" ] || die "no $p package in $PORTS_PKGS"
	set -- "$@" "$f"
done
say "==> adding $ADD"
xpkg --quiet --no-scripts install "$@" >"$STAGE.add.log" 2>&1 || {
	tail -20 "$STAGE.add.log" >&2
	die 'adding the console packages failed'
}
ln -sf ../../bin/mandoc "$STAGE/usr/bin/man"
for n in apropos whatis; do
	[ -e "$STAGE/usr/bin/$n" ] || ln -sf ../../bin/mandoc "$STAGE/usr/bin/$n"
done
# vi is vim.  The nvi in the desktop tree (and the nvi2 port) calls
# getprogname() undeclared, so the pointer is truncated to int and it crashes
# on start; nvi2 also needs Berkeley db1, which nothing here builds.
rm -f "$STAGE/bin/nvi" "$STAGE/usr/bin/nvi" "$STAGE/bin/vi"
ln -s vim "$STAGE/bin/vi"

# Manual pages for the commands base ships, from the NetBSD source tree the
# userland was built from (bin, sbin, usr.bin, usr.sbin) and from the ports
# that carry their own (tmux, curl, OpenSSH).  The desktop shipped almost
# none, so `man ls` had nothing to show.
NETBSD_SRC=${NETBSD_SRC:-$ROOT/ports/build/work/netbsd-sh}
PORTS_WORK=$ROOT/ports/build/work
if [ -d "$NETBSD_SRC/usr.bin" ]; then
	n_man=0
	for d in bin sbin usr/bin usr/sbin; do
		for f in "$STAGE/$d"/*; do
			[ -e "$f" ] || continue
			c=${f##*/}
			# a toybox applet is not the NetBSD command of that name
			case $(readlink "$f" 2>/dev/null) in *toybox*) continue ;; esac
			for p in "$NETBSD_SRC"/bin/"$c"/"$c".[18] \
			    "$NETBSD_SRC"/sbin/"$c"/"$c".[18] \
			    "$NETBSD_SRC"/usr.bin/"$c"/"$c".[18] \
			    "$NETBSD_SRC"/usr.sbin/"$c"/"$c".[18] \
			    "$PORTS_WORK"/"$c"/"$c"-*/"$c".[18] \
			    "$PORTS_WORK"/"$c"/"$c"-*/docs/cmdline-opts/"$c".1 \
			    "$PORTS_WORK"/openssh/openssh-*/"$c".[18]; do
				[ -f "$p" ] || continue
				s=${p##*.}
				[ -e "$STAGE/usr/share/man/man$s/$c.$s" ] && break
				mkdir -p "$STAGE/usr/share/man/man$s"
				cp "$p" "$STAGE/usr/share/man/man$s/$c.$s"
				n_man=$((n_man + 1))
				break
			done
		done
	done
	say "    $n_man manual pages from the NetBSD tree"
else
	# src/rootfs carries the NetBSD pages for what it ships, so a fresh
	# checkout without ports/build/work still has them
	say "    no NetBSD source tree at $NETBSD_SRC: the pages in src/rootfs are used"
fi
# The index man -k and apropos read.  mandoc is static, so the host can run
# it; invoked as makewhatis (mandoc picks the mode from its name) it builds
# mandoc.db.
mkdir -p "$STAGE.tools"
ln -sf "$STAGE/bin/mandoc" "$STAGE.tools/makewhatis"
"$STAGE.tools/makewhatis" "$STAGE/usr/share/man" || die 'makewhatis failed'
rm -rf "$STAGE.tools"
say "    $(find "$STAGE/usr/share/man" -type f -name '*.[0-9]' | wc -l) manual pages in all"

# cc (tcc) that compiles: the desktop shipped tcc with no libc headers, no
# crt*.o and no libtcc1.a, so `cc hello.c` failed on stdio.h and crt1.o.
# musl's headers, the kernel UAPI headers, musl's start files, and the tcc port
# with its runtime.
#
# A configured musl source tree is used when there is one, because installing
# from it is exact.  There is not one outside the desktop flow, and requiring it
# anyway meant a base build needed a tree it had no other use for.  The sysroot
# carries the same headers, because the sysroot was made by installing musl
# into it, so they are copied from there when there is no musl tree to install
# from.  libc++ is left behind: this image has no C++ compiler, and shipping a
# C++ standard library's headers to a machine whose compiler is tcc is the kind
# of thing that makes `ls /usr/include` unreadable.
if xpkg info musl-dev >/dev/null 2>&1; then
	# The musl-dev package (installed with the KEEP packages from the
	# repository) is exactly these: musl's headers, the kernel UAPI headers and
	# crt*.o, registered as a package.
	say "    libc headers and start files: the musl-dev package"
else
	if [ -n "${MUSL_SRC:-}" ] || [ -f "$DESK/stack/work/src/musl/musl-1.2.5/config.mak" ]; then
		MUSL_SRC=${MUSL_SRC:-$DESK/stack/work/src/musl/musl-1.2.5}
		[ -f "$MUSL_SRC/config.mak" ] || die "no configured musl tree at $MUSL_SRC"
		make -s -C "$MUSL_SRC" DESTDIR="$STAGE" install-headers >/dev/null ||
			die 'installing the musl headers failed'
	else
		[ -f "$SYS_INC/stdio.h" ] ||
			die "the sysroot at $SYSROOT has no libc headers ($SYS_INC/stdio.h)"
		for h in "$SYS_INC"/*; do
			[ "${h##*/}" = c++ ] || cp -R "$h" "$STAGE/usr/include/"
		done
		say "    libc headers from $SYS_INC"
	fi
	for d in linux asm asm-generic; do
		[ -d "$SYS_INC/$d" ] || die "the sysroot at $SYSROOT has no $d/ UAPI headers"
		cp -R "$SYS_INC/$d" "$STAGE/usr/include/"
	done
	# crt1.o is what every dynamically linked program starts with, and crti.o and
	# crtn.o bracket it; Scrt1.o and rcrt1.o are the PIE and static-PIE variants,
	# and a musl configured without PIE support does not build them.  So the two
	# that must exist are required, and the ones that may not are named in the
	# build log instead of aborting it: `cp` on a missing file dies with a path and
	# no reason, which is the worst possible way to learn a sysroot has no Scrt1.o.
	have_crt=
	for o in crt1.o crti.o crtn.o Scrt1.o rcrt1.o; do
		[ -f "$SYS_LIB/$o" ] || continue
		cp "$SYS_LIB/$o" "$STAGE/usr/lib/$o"
		have_crt="$have_crt $o"
	done
	for o in crt1.o crti.o crtn.o; do
		case $have_crt in
		*" $o "*) ;;
		*) die "the sysroot at $SYSROOT has no $o: a C compiler cannot link a program without it" ;;
		esac
	done
	case $have_crt in
	*' Scrt1.o '*) ;;
	*) say '    note: this sysroot has no Scrt1.o, so tcc cannot build a PIE binary' ;;
	esac
fi
rm -f "$STAGE/usr/bin/tcc"
f=$(ls "$PORTS_PKGS"/tcc-[0-9]*.xpkg 2>/dev/null | sort -V | tail -1)
[ -n "$f" ] || die "no tcc package in $PORTS_PKGS"
xpkg --quiet --no-scripts install "$f" >>"$STAGE.add.log" 2>&1 || {
	tail -5 "$STAGE.add.log" >&2
	die 'installing tcc failed'
}
ln -sf tcc "$STAGE/usr/bin/cc"
say "    C compiler: tcc, musl headers ($(du -sh "$STAGE/usr/include" | cut -f1))"

# file(1) is 5.46 but the desktop's magic.mgc came from an older file, so
# every `file` said "not a multiple of 432".  Compile the database from the
# 5.46 sources with this file binary (dynamic musl: run it with the stage's
# own loader).
FILE_SRC=${FILE_SRC:-$ROOT/ports/dist/file-5.46.tar.gz}
if [ ! -f "$FILE_SRC" ]; then
	# ports/dist is a download cache, not in git: take the tarball from the
	# FreeLinX source mirror, checked against the sum recorded for it there.
	FILE_SUM=c9cc77c7c560c543135edc555af609d5619dbef011997e988ce40a3d75d86088
	FILE_SRC=$STAGE.file-5.46.tar.gz
	say "==> fetching file-5.46.tar.gz from the source mirror (for magic.mgc)"
	curl -sfL --retry 3 -o "$FILE_SRC" \
		https://huggingface.co/datasets/FreeLinX/sources/resolve/main/ports/file-5.46.tar.gz ||
		die "no file source in ports/dist, and the source mirror could not be reached"
	printf '%s  %s\n' "$FILE_SUM" "$FILE_SRC" | sha256sum -c - >/dev/null 2>&1 ||
		die 'file-5.46.tar.gz from the mirror does not match its sum'
fi
mkdir -p "$STAGE.magic"
tar -xzf "$FILE_SRC" -C "$STAGE.magic"
( cd "$STAGE.magic" &&
  "$STAGE/lib/ld-musl-x86_64.so.1" --library-path "$STAGE/usr/lib:$STAGE/lib" \
	"$STAGE/usr/bin/file" -C -m file-*/magic/Magdir ) ||
	die 'compiling magic.mgc failed'
mv -f "$STAGE.magic/Magdir.mgc" "$STAGE/usr/share/misc/magic.mgc"
rm -rf "$STAGE.magic"

# mksh for people, /bin/sh for scripts.  /etc/flx-shell is what xsetup
# and flxadduser give new users and what /etc/profile sets SHELL to.
printf '/bin/mksh\n' >"$STAGE/etc/flx-shell"
printf '/bin/sh\n/bin/mksh\n' >"$STAGE/etc/shells"
sed -i -e 's#^\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)/bin/sh$#\1/bin/mksh#' \
	-e 's#^\(live:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)/bin/sh$#\1/bin/mksh#' "$STAGE/etc/passwd"
grep -q '^root:.*:/bin/mksh$' "$STAGE/etc/passwd" || die "root's shell is not mksh"
# The console shell has to come from the same file.  This used to sed
# `setsid -c /bin/sh -l` in var/service/shell/run and then insist the result
# said /bin/mksh -l.  That run script is now `exec /sbin/flxconsole`, so the sed
# changed nothing and the grep died: base could not be built at all.  What
# matters is that one file names the shell for people, so that is what is asked.
[ -f "$STAGE/sbin/flxconsole" ] ||
	die 'there is no /sbin/flxconsole to put a login shell on a console with'
grep -q '/etc/flx-shell' "$STAGE/sbin/flxconsole" ||
	die 'flxconsole names a shell of its own instead of reading /etc/flx-shell'

# which: the shell has `command -v`; scripts and people still type which.
printf '%s\n' '#!/bin/sh' \
	'# which NAME... - the path the shell would run for each NAME.' \
	'r=0' \
	'for n do' \
	'	p=$(command -v "$n") || { r=1; continue; }' \
	'	case $p in /*) printf "%s\n" "$p" ;; *) r=1 ;; esac' \
	'done' \
	'exit $r' >"$STAGE/usr/bin/which"
chmod 755 "$STAGE/usr/bin/which"

# --- 4c. the installer: xsetup -------------------------------------------------
# Base installs with xsetup, step by step (setup-keymap ... setup-apkcache);
# the desktop's flxinstall is not shipped.  xsetup lives in
# /usr/libexec/xsetup (it finds lib/ and xsetup.d/ next to itself) and
# /sbin/xsetup runs it.
rm -f "$STAGE/sbin/flxinstall"
X=$STAGE/usr/libexec/xsetup
rm -rf "$X"
mkdir -p "$X/lib" "$X/xsetup.d"
cp "$HERE/../xsetup" "$X/xsetup"
cp "$HERE/../lib/ui.sh" "$X/lib/"
cp "$HERE"/../xsetup.d/*.sh "$X/xsetup.d/"
chmod 755 "$X/xsetup"
printf '%s\n' '#!/bin/sh' 'exec /usr/libexec/xsetup/xsetup "$@"' >"$STAGE/sbin/xsetup"
chmod 755 "$STAGE/sbin/xsetup"

# Services xsetup turns on and off: setup-ntp and setup-sshd link
# /etc/svc/NAME into /var/service.  ntpd is on by default.
mkdir -p "$STAGE/etc/svc"
if [ -d "$STAGE/var/service/ntpd" ] && [ ! -L "$STAGE/var/service/ntpd" ]; then
	mv "$STAGE/var/service/ntpd" "$STAGE/etc/svc/ntpd"
fi
ln -sfn /etc/svc/ntpd "$STAGE/var/service/ntpd"
mkdir -p "$STAGE/etc/svc/openssh"
printf '%s\n' '#!/bin/sh' \
	'# OpenSSH server, enabled by xsetup setup-sshd.  Host keys are made on' \
	'# first start if missing.' \
	'ssh-keygen -A >/dev/null 2>&1' \
	'exec /bin/sshd -D -e 2>>/var/log/sshd.log' >"$STAGE/etc/svc/openssh/run"
chmod 755 "$STAGE/etc/svc/openssh/run"
mkdir -p "$STAGE/etc/ssh" "$STAGE/var/empty"
chmod 755 "$STAGE/var/empty"
cat >"$STAGE/etc/ssh/sshd_config" <<'EOF'
# FreeLinX sshd configuration.  See sshd_config(5).
PermitRootLogin prohibit-password
PasswordAuthentication yes
KbdInteractiveAuthentication no
Subsystem sftp /libexec/sftp-server
EOF
# the privilege-separation user: locked, and no shell to log in to
grep -q '^sshd:' "$STAGE/etc/group" ||
	printf 'sshd:x:22:\n' >>"$STAGE/etc/group"
grep -q '^sshd:' "$STAGE/etc/passwd" ||
	printf 'sshd:x:22:22:sshd privsep:/var/empty:/sbin/nologin\n' >>"$STAGE/etc/passwd"
grep -q '^sshd:' "$STAGE/etc/shadow" ||
	printf 'sshd:!:0:0:99999:7:::\n' >>"$STAGE/etc/shadow"

# --- 5. console login --------------------------------------------------------
# Nothing to build here.  var/service/shell already is this: it is
# `exec /sbin/flxconsole`, which opens every console the kernel gave the machine
# and puts a login shell on each.  greetd, which is what it replaces, is in
# UNOWNED.
#
# There used to be a var/service/console written here as well - "what greetd's
# run script did when there was no desktop, and nothing else".  It could not
# work: it exec'd /usr/bin/getty, /usr/libexec/toybox/login and /usr/bin/setsid,
# and none of the three exist here.  toybox is installed as /bin/toybox with no
# applet symlinks anywhere, so there is no /usr/bin/getty and no
# /usr/libexec/toybox/ to put one in; runsvdir restarted it about once a second
# for the life of the system.  It also wanted /dev/tty1, which flxconsole was
# already holding a shell on.
#
# /etc/issue and /etc/motd are not touched here either.  They arrive from the
# desktop, and both attempts to clean them up in this script failed: the sed
# named a line the desktop banner does not have, and the check after it refused
# the file for still containing the word "desktop", which it did in four other
# lines.  build-base.sh writes both files outright.
[ -f "$STAGE/var/service/shell/run" ] ||
	die 'var/service/shell is gone, so nothing would put a prompt on the screen'

# --- 6. checks ---------------------------------------------------------------
# --- 5b. minimal ---------------------------------------------------------------
# Things the source tree carries that a console system has no use for.
#   bin/openssl       not a program: a 10 MB static library (ar archive) under a
#                     program's name; the real openssl is /usr/bin/openssl
#   *.a nobody owns   static libraries for C++ and stubs; there is no C++
#                     compiler here and tcc links against libc.so
#   vim testdirs      vim's own regression tests (13 MB)
#   doom              a game and its 4 MB data file
say '==> trimming to a minimal system'
if [ -f "$STAGE/bin/openssl" ] && ! head -c4 "$STAGE/bin/openssl" | grep -q ELF; then
	rm -f "$STAGE/bin/openssl"
fi
owned=$STAGE.owned
for p in $(xpkg list | awk '{ print $1 }'); do xpkg files "$p"; done 2>/dev/null >"$owned" || :
for f in "$STAGE"/usr/lib/*.a "$STAGE"/lib/*.a; do
	[ -f "$f" ] || continue
	grep -qxF "/${f#"$STAGE"/}" "$owned" || rm -f "$f"
done
rm -f "$owned"
rm -rf "$STAGE"/usr/share/vim/vim*/*/testdir "$STAGE/bin/doom" "$STAGE/usr/games/doom" \
	"$STAGE/usr/share/games/doom"

say '==> checking that every library is still there'
missing=$(find "$STAGE" -type f \( -perm -u+x -o -name '*.so*' \) | while read -r f; do
	head -c4 "$f" 2>/dev/null | grep -q ELF || continue
	readelf -d "$f" 2>/dev/null |
		sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | while read -r n; do
		[ -e "$STAGE/lib/$n" ] || [ -e "$STAGE/usr/lib/$n" ] ||
			printf '  %s needs %s\n' "${f#"$STAGE"/}" "$n"
	done
done || :)
[ -z "$missing" ] || die "libraries missing after the strip:
$missing"

say '==> checking for graphical programs'
gui=$(find "$STAGE" -type f | while read -r f; do
	head -c4 "$f" 2>/dev/null | grep -q ELF || continue
	grep -aqE 'XOpenDisplay|wl_display_connect|xcb_connect|gtk_init' "$f" &&
		printf '  %s\n' "${f#"$STAGE"/}"
done || :)
[ -z "$gui" ] || die "graphical programs left in the rootfs:
$gui"

say '==> check-nognu'
sh "$CHECK_NOGNU" "$STAGE" | tail -1
sh "$CHECK_NOGNU" "$STAGE" >/dev/null || die 'check-nognu failed'

say "==> base rootfs: $STAGE ($(du -sh "$STAGE" | cut -f1), $(xpkg list | wc -l) packages)"
