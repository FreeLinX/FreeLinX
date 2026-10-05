#!/bin/sh
# test-banner.sh - what build-base.sh writes into /etc/issue and /etc/motd.
#
# The banner is the only thing a person sees between the boot log and the
# prompt, and it is written in build-base.sh, which cannot be run here: it needs
# a FreeLinX-desk tree that is not in git.  So the block is lifted out of the
# script and run on its own, against a scratch directory.  What it writes is
# then checked.
#
# Two bugs this catches, both of which shipped:
#
#   1.0.11 carried a /etc/issue whose backslashes were doubled - \_/ where
#   /etc/motd had \/ - so the logo drew with a double stroke on an SSH login.
#   Both files come from one heredoc now, so asking for them to be identical is
#   what stops one of them drifting again.
#
#   The banner arrived from the desktop as a Plan 9 Rio screen, and mkrootfs.sh
#   refused to build if the word "desktop" survived in it.  It survived in four
#   lines, so a fresh clone could not produce an image at all.
#
# The banner itself is plain text, not art: the version line, a blank line,
# then what the session is and what to type.  What is checked is that no
# ASCII art crept back in above the version line.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
STAGE=$TMP/stage
mkdir -p "$STAGE/etc" || exit 2

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

# --- lift the block out of build-base.sh -------------------------------------
sed -n '/^for f in etc\/motd etc\/issue; do$/,/^done$/p' \
	"$HERE/build-base.sh" >"$TMP/block.sh"
if ! grep -q 'etc/motd' "$TMP/block.sh"; then
	printf 'test-banner: build-base.sh has no etc/motd block to test\n' >&2
	exit 2
fi

# die() and VERSION are build-base.sh's; give the block what it expects.
{
	printf 'VERSION=9.9.9\n'
	printf 'die() { printf "die: %%s\\n" "$1" >&2; exit 1; }\n'
	cat "$TMP/block.sh"
} >"$TMP/run.sh"

echo '== build-base.sh writes both banners =='
if STAGE=$STAGE sh "$TMP/run.sh"; then
	ok 'the banner block runs and does not die'
else
	no 'the banner block died'
	printf '       nothing below could be checked\n'
	printf '%d passed, %d failed\n' "$pass" "$fail"
	exit 1
fi

for f in motd issue; do
	[ -s "$STAGE/etc/$f" ] || no "/etc/$f is empty or missing"
done

echo '== the version is stamped =='
# 9.9.9 cannot collide with a real version, so this cannot pass by accident.
for f in motd issue; do
	if grep -q '^ FreeLinX 9\.9\.9 base$' "$STAGE/etc/$f"; then
		ok "/etc/$f carries the version"
	else
		no "/etc/$f has no version line"
	fi
done

echo '== nothing about a desktop =='
for f in motd issue; do
	if grep -qi 'desktop\|rio workstation\|plan 9' "$STAGE/etc/$f"; then
		no "/etc/$f still talks about a desktop"
		grep -in 'desktop\|rio workstation\|plan 9' "$STAGE/etc/$f" |
			sed 's/^/       /'
	else
		ok "/etc/$f does not talk about a desktop"
	fi
done

echo '== the two files agree =='
# The 1.0.11 defect: /etc/issue was escaped and /etc/motd was not, so the same
# logo drew two different ways depending on how you reached the machine.
if diff "$STAGE/etc/motd" "$STAGE/etc/issue" >"$TMP/diff" 2>&1; then
	ok '/etc/motd and /etc/issue are the same file'
else
	no '/etc/motd and /etc/issue differ'
	sed 's/^/       /' "$TMP/diff"
fi

echo '== the banner is plain text, not art =='
# No ASCII art: the block above the first blank line is the version line
# alone, the way real systems keep /etc/issue and /etc/motd.  Artwork here
# drew differently on every console, so what is asked is that there is
# none: one line above the blank line, and it is the version line.
ART=$TMP/art
awk 'NF==0{exit} {print}' "$STAGE/etc/motd" >"$ART"
lines=$(wc -l <"$ART")
if [ "$lines" -eq 1 ] && grep -q '^ FreeLinX 9\.9\.9 base$' "$ART"; then
	ok 'the banner opens with the version line alone, no art above it'
else
	no "the banner does not open with the version line alone ($lines lines above the blank line)"
	sed 's/^/       /' "$ART"
fi
# Without art there is no reason for a backslash anywhere in the file.
# (This used to allow single backslashes and only refused doubled ones,
# from when the logo drew with a double stroke on SSH logins in 1.0.11.)
if grep -q '\\' "$STAGE/etc/motd" "$STAGE/etc/issue"; then
	no 'a backslash survived in a banner with no art in it'
	grep -n '\\' "$STAGE/etc/motd" "$STAGE/etc/issue" | sed 's/^/       /'
else
	ok 'no backslashes in either file'
fi
# A tab in the banner is eight columns wherever it falls, so columns stop
# lining up.  There is no reason for the banner to contain one, and it is
# the sort of thing that arrives by pasting.
if grep -q "$(printf '\t')" "$ART"; then
	no 'the banner has a tab in it, which will not line up on a terminal'
	grep -n "$(printf '\t')" "$ART" | sed 's/^/       /'
else
	ok 'no tab in the banner'
fi

echo '== it says how to install =='
for f in motd issue; do
	if grep -q '^ Install to disk: xsetup' "$STAGE/etc/$f"; then
		ok "/etc/$f says what to type"
	else
		no "/etc/$f does not say how to install"
	fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
