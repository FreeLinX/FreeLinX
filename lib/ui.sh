#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# ui.sh - prompts, menus and messages for xsetup.
#
# Sourced by xsetup and by every step in xsetup.d.  Nothing here runs a
# command or touches the disk; it is the only place that talks to the user, so
# every step looks and behaves the same way.

C_RED=''
C_GREEN=''
C_CYAN=''
C_YELLOW=''
C_BOLD=''
C_OFF=''

# Colour only when stdout is a terminal.  Piping xsetup into a file, or
# running it over serial with no tty, should give plain text.
if [ -t 1 ]; then
	C_RED=$(printf '\033[31m')
	C_GREEN=$(printf '\033[32m')
	C_CYAN=$(printf '\033[36m')
	C_YELLOW=$(printf '\033[33m')
	C_BOLD=$(printf '\033[1m')
	C_OFF=$(printf '\033[0m')
fi

# say MESSAGE... - ordinary progress output.
say() {
	printf '%s\n' "$*"
}

# info MESSAGE... - a labelled line, for "here is what I am about to do".
info() {
	printf '%s==>%s %s\n' "$C_CYAN$C_BOLD" "$C_OFF" "$*"
}

# ok MESSAGE... - something finished successfully.
ok() {
	printf '%s  ok%s %s\n' "$C_GREEN" "$C_OFF" "$*"
}

# warn MESSAGE... - non-fatal trouble the user should know about.
warn() {
	printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2
}

# die MESSAGE... - give up.  Exits, so a step never carries on past this.
die() {
	printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
	exit 1
}

# ask PROMPT [DEFAULT] - read one line.  An empty answer takes the default.
ask() {
	_prompt=$1
	_default=${2:-}
	_reply=
	if [ -n "$_default" ]; then
		printf '%s' "$_prompt [$_default]: " >&2
	else
		printf '%s' "$_prompt: " >&2
	fi
	# read returns non-zero at EOF, which is not an error to retry: a closed
	# stdin means the user is gone, and looping here would spin forever.
	if ! IFS= read -r _reply; then
		printf '\n' >&2
		die 'input ended before anything was entered'
	fi
	[ -n "$_reply" ] || _reply=$_default
	printf '%s' "$_reply"
}

# ask_yes PROMPT [DEFAULT] - a yes/no question.  DEFAULT is y or n.
ask_yes() {
	_prompt=$1
	_default=${2:-y}
	case $_default in
	y|Y) _hint='[Y/n]' ;;
	*)   _hint='[y/N]' ;;
	esac
	while :; do
		# See choose: ask runs in a substitution, so EOF has to be caught
		# by testing the status rather than trusting ask to stop us.
		if ! _reply=$(ask "$_prompt [$_hint]" ''); then
			return 1
		fi
		case $_reply in
		''|y|Y|yes|Yes|YES) return 0 ;;
		n|N|no|No|NO)     return 1 ;;
		esac
		warn "answer y or n"
	done
}

# choose PROMPT ITEM... - numbered menu, returns the chosen item's argument.
#
# The last argument is the value returned; everything before it is what the
# user sees.  This is what makes a menu a menu: the caller never has to map a
# number back to a value, and a menu can never be accidentally muted, because
# there is no code path here that hides the list.
# choose PROMPT VALUE LABEL... - numbered menu, returns VALUE.
#
# The value comes first and the labels follow, so a label never has to be
# repeated as the value and the menu shows exactly the choices there are.
# Nothing here can mute the list: the labels are the only way to answer, so a
# caller that wants a menu gets a menu.
#
#     disk=$(choose 'Pick a disk' /dev/sda '/dev/sda  100 GB' '/dev/sdb  500 GB')
choose() {
	_prompt=$1
	_value=$2
	shift 2
	_n=$#

	printf '%s%s%s\n' "$C_BOLD" "$_prompt" "$C_OFF" >&2
	_i=1
	while [ "$_i" -le "$_n" ]; do
		# Labels sit at 1.._n after the shift.  _i is a literal integer
		# here, so this cannot be used to read an arbitrary variable.
		printf '  %s) %s\n' "$_i" "${!_i}" >&2
		_i=$((_i + 1))
	done

	while :; do
		# ask dies on EOF, but it runs inside a command substitution, so its
		# exit only ends the substitution.  Testing the status here is the
		# only way the loop learns that input has ended; without this it
		# re-prompts forever.
		if ! _reply=$(ask 'choice' ''); then
			exit 1
		fi
		case $_reply in
		'')
			warn 'nothing chosen'
			continue
			;;
		*[!0-9]*)
			warn "'$_reply' is not a number"
			continue
			;;
		esac
		if [ "$_reply" -ge 1 ] && [ "$_reply" -le "$_n" ]; then
			printf '%s' "$_value"
			return 0
		fi
		warn "choose 1 to $_n"
	done
}

# confirm PROMPT - ask for a word and insist it matches, for anything that
# destroys a disk.
confirm() {
	_prompt=$1
	while :; do
		if ! _reply=$(ask "$_prompt, type 'yes' to continue" ''); then
			return 1
		fi
		[ "$_reply" = yes ] && return 0
		warn "type 'yes' exactly, or nothing happens"
	done
}

# need_cmd NAME [HINT] - fail unless NAME can be run.
#
# A step that quietly does half its job is worse than one that stops, so a
# step checks its tooling up front and says which port supplies what is
# missing.  HINT names the port, because "command not found" is not something
# the person holding the keyboard can act on.
need_cmd() {
	command -v "$1" >/dev/null 2>&1 && return 0
	if [ -n "${2:-}" ]; then
		die "$1 is not installed, so this step cannot do its job.
     It comes from the $2 port."
	fi
	die "$1 is not installed, so this step cannot do its job."
}

# need_root - fail unless running as root.
need_root() {
	[ "$(id -u)" = 0 ] || die 'this step has to be root: it writes to /etc'
}

# step_start N NAME - banner at the top of each of the twelve steps.
step_start() {
	printf '\n%s%s[%s/%s] %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$2" "$3" "$C_OFF"
}

# done_message - printed by xsetup when every step has been run.
done_message() {
	printf '\n%s%sSetup complete.%s\n' "$C_BOLD" "$C_GREEN" "$C_OFF"
	printf 'Reboot to start the installed system.\n'
}
