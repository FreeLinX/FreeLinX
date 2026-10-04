#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# host-xpkg.sh - get an xpkg that runs on this machine, from the repository.
#
#   sh scripts/host-xpkg.sh DIR [REPO]
#
# Prints the command that runs it.  The build installs packages with xpkg, and
# the only xpkg binaries are FreeLinX ones (dynamic musl), so a machine without
# one has nothing to run.  This fetches the xpkg package and the libraries it
# needs (musl, openssl, sqlite, zlib) into DIR and runs xpkg through that musl's
# own loader: no install, no root.
#
# Trust: the index is checked against keys/freelinx.pub (Ed25519) before
# anything in it is believed, and every archive against the index's sha256 -
# the check xpkg itself makes, made once by hand before there is an xpkg.
#
# Needs curl, tar, sha256sum, python3, and openssl 3 or python3-cryptography.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${1:?usage: host-xpkg.sh DIR [REPO]}
REPO=${2:-https://huggingface.co/datasets/FreeLinX/packages/resolve/main}
KEY=$HERE/../keys/freelinx.pub
NEED='musl openssl sqlite zlib xpkg'

die() { printf 'host-xpkg: %s\n' "$*" >&2; exit 1; }
for t in curl tar sha256sum python3; do
	command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

rm -rf "$DIR"
mkdir -p "$DIR/root" "$DIR/dl"
curl -sfL --retry 3 -o "$DIR/dl/index.json" "$REPO/index.json" ||
	die "cannot fetch $REPO/index.json"
curl -sfL --retry 3 -o "$DIR/dl/index.json.sig" "$REPO/index.json.sig" ||
	die "cannot fetch $REPO/index.json.sig"

# --- the signature ---------------------------------------------------------------
# keys/freelinx.pub is the raw 32-byte Ed25519 key in base64; openssl wants it
# as SubjectPublicKeyInfo: a fixed 12-byte DER header, then the key.
verified=
if command -v openssl >/dev/null 2>&1; then
	{ printf '\060\052\060\005\006\003\053\145\160\003\041\000'; base64 -d <"$KEY"; } >"$DIR/dl/key.der"
	base64 -d <"$DIR/dl/index.json.sig" >"$DIR/dl/index.sig.bin"
	if openssl pkey -pubin -inform DER -in "$DIR/dl/key.der" -out "$DIR/dl/key.pem" 2>/dev/null &&
	   openssl pkeyutl -verify -pubin -inkey "$DIR/dl/key.pem" -rawin \
		-in "$DIR/dl/index.json" -sigfile "$DIR/dl/index.sig.bin" >/dev/null 2>&1; then
		verified=openssl
	fi
fi
if [ -z "$verified" ]; then
	python3 - "$DIR/dl/index.json" "$KEY" <<'EOF' 2>/dev/null && verified=python3
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
data = open(sys.argv[1], "rb").read()
sig = base64.b64decode(open(sys.argv[1] + ".sig").read().strip())
Ed25519PublicKey.from_public_bytes(base64.b64decode(open(sys.argv[2]).read().strip())).verify(sig, data)
EOF
fi
[ -n "$verified" ] || die "the index at $REPO does not verify against keys/freelinx.pub"

# --- the archives -------------------------------------------------------------------
python3 - "$DIR/dl/index.json" $NEED >"$DIR/dl/want" <<'EOF' || die 'a package xpkg needs is not in the index'
import json, sys
p = json.load(open(sys.argv[1]))["packages"]
for n in sys.argv[2:]:
    print(p[n]["file"], p[n]["sha256"])
EOF
while read -r f sum; do
	curl -sfL --retry 3 -o "$DIR/dl/$f" "$REPO/$f" || die "cannot fetch $f"
	printf '%s  %s\n' "$sum" "$DIR/dl/$f" | sha256sum -c - >/dev/null 2>&1 ||
		die "$f does not match the signed index"
	tar -xzf "$DIR/dl/$f" -C "$DIR/root" files
done <"$DIR/dl/want"

R=$DIR/root/files
[ -x "$R/lib/ld-musl-x86_64.so.1" ] && [ -x "$R/usr/bin/xpkg" ] ||
	die 'the packages did not contain a runnable xpkg'
X="$R/lib/ld-musl-x86_64.so.1 --library-path $R/usr/lib:$R/lib $R/usr/bin/xpkg"
# shellcheck disable=SC2086
$X --version >/dev/null 2>&1 || die 'the fetched xpkg does not run on this machine'
printf '%s\n' "$X"
