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
# The logo itself is checked for shape, not compared against a copy kept here:
# it is released artwork, 1.0.8 through 1.0.11, and it is not this file's to
# change.
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

if grep -q '\\\\' "$STAGE/etc/motd" "$STAGE/etc/issue"; then
	no 'a backslash is doubled, so the logo draws with a double stroke'
	grep -n '\\\\' "$STAGE/etc/motd" "$STAGE/etc/issue" | sed 's/^/       /'
else
	ok 'no doubled backslashes in either file'
fi

echo '== the logo is still there =='
# Shape only.  Six lines, an underscore rule first and a backslash rule last,
# which is what makes it the FreeLinX logo rather than any six lines.
if [ "$(wc -l <"$STAGE/etc/motd")" -ge 6 ]; then
	ok 'the banner is long enough to hold the logo'
else
	no "the banner is only $(wc -l <"$STAGE/etc/motd") lines; the logo is gone"
fi
if sed -n '1p' "$STAGE/etc/motd" | grep -q '^  ______'; then
	ok 'the logo starts with its underscore rule'
else
	no 'the logo is not where it was'
fi
if sed -n '6p' "$STAGE/etc/motd" | grep -q '|\\_\\$'; then
	ok 'the logo ends with its backslash rule'
else
	no 'the logo is cut short or its last line is wrong'
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
