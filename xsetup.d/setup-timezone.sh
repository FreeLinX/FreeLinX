#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-timezone - set the local time zone.
#
# A zone is a file under /usr/share/zoneinfo, and the system is told which
# one by /etc/localtime being a copy of it.  A copy rather than a symlink
# because a symlink breaks the moment the zone database is upgraded or the
# disk is mounted somewhere else.  /etc/timezone names the zone in text, for
# the things that cannot follow a link.

need_root

ZONEINFO=/usr/share/zoneinfo

if [ ! -d "$ZONEINFO" ]; then
	die "there is no $ZONEINFO, so no zone can be selected.
     The zone database comes from the base/tzdata port."
fi

# The zones are nested Region/City, and some are deeper still
# (America/Argentina/Buenos_Aires), so the whole tree is flattened once and
# the menu is driven off that: region first, then the city within it, which
# is how anyone actually looks for a zone.  A single flat list of 600 zones
# would be unusable.
zones_list() {
	find "$ZONEINFO" -type f 2>/dev/null |
		sed "s|^$ZONEINFO/||" |
		grep -vE '(^|/)(posix|right)(/|$)' |
		grep -v '\.tab$' |
		grep -vE '^(\.|localtime|posixrules|leapseconds|Factory)$' |
		sort
}

zones=$(zones_list)

if [ -z "$zones" ]; then
	die "$ZONEINFO is there but empty."
fi

zone=
while :; do
	regions=$(printf '%s\n' "$zones" | cut -d/ -f1 | sort -u)
	# Word splitting is wanted here: the region names have no spaces in
	# them, and the labels are quoted so choose gets them as one word each.
	# shellcheck disable=SC2086
	region=$(choose 'Region' none $(printf '%s\n' $regions | sed 's/^/"/; s/$/"/'))
	[ "$region" = none ] && die 'no time zone was chosen'
	[ "$region" = UTC ] && { zone=UTC; break; }

	cities=$(printf '%s\n' "$zones" | grep "^$region/")
	if [ "$(printf '%s\n' "$cities" | wc -l | tr -d ' ')" -le 40 ]; then
		# shellcheck disable=SC2086
		zone=$(choose "City in $region" none \
			$(printf '%s\n' $cities | sed 's/^/"/; s/$/"/'))
		[ "$zone" = none ] && continue
		break
	fi
	printf '  %s has too many zones for a list; type the full name.\n' "$region"
	zone=$(ask "Time zone under $region" '')
	case $zone in
	"$region"/*) break ;;
	*) warn "that is not a zone under $region" ;;
	esac
done

[ -n "$zone" ] || die 'no time zone was chosen'

src=$ZONEINFO/$zone
[ -f "$src" ] || die "$src is not a file, so it cannot be copied"

info "setting the time zone to $zone"
cp "$src" /etc/localtime
printf '%s\n' "$zone" >/etc/timezone

# /etc/localtime is a copy, so its mode should say so plainly.
chmod 644 /etc/localtime

ok "time zone is $zone"
