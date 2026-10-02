#!/bin/sh
# Exercises lib/ui.sh, in particular the EOF case that used to hang.
set -u
cd "$(dirname "$0")" || exit 1
. lib/ui.sh

pass=0
fail=0

ok_is() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1))
		printf '  FAIL %s: want [%s] got [%s]\n' "$1" "$3" "$2"
	fi
}

echo "== ask: default on empty input =="
ok_is 'ask empty takes default' "$(printf '\n' | ask Name bob)" 'bob'

echo "== ask: typed value wins =="
ok_is 'ask typed' "$(printf 'alice\n' | ask Name bob)" 'alice'

echo "== ask: EOF must die, not spin =="
_out=$( (ask Name bob </dev/null) 2>&1 )
case $_out in
*'input ended'*) pass=$((pass+1)); printf '  ok   ask EOF dies\n' ;;
*) fail=$((fail+1)); printf '  FAIL ask EOF: got [%s]\n' "$_out" ;;
esac

echo "== ask_yes =="
if printf 'y\n' | ask_yes Go; then pass=$((pass+1)); printf '  ok   ask_yes y\n'; else fail=$((fail+1)); printf '  FAIL ask_yes y\n'; fi
if printf 'n\n' | ask_yes Go; then fail=$((fail+1)); printf '  FAIL ask_yes n returned true\n'; else pass=$((pass+1)); printf '  ok   ask_yes n\n'; fi

echo "== choose: first, middle, last =="
ok_is 'choose 1'  "$(printf '1\n' | choose Pick RED 'red' GREEN 'green' BLUE 'blue')"   'RED'
ok_is 'choose 2'  "$(printf '2\n' | choose Pick RED 'red' GREEN 'green' BLUE 'blue')"   'GREEN'
ok_is 'choose 3'  "$(printf '3\n' | choose Pick RED 'red' GREEN 'green' BLUE 'blue')"   'BLUE'

echo "== choose: single item =="
ok_is 'choose 1 of 1' "$(printf '1\n' | choose Only SOLO 'the only one')" 'SOLO'

echo "== choose: out of range, then valid =="
ok_is 'choose retries after 9' "$(printf '9\n0\n2\n' | choose Pick RED 'red' GREEN 'green' BLUE 'blue')" 'GREEN'

echo "== choose: non-numeric, then valid =="
ok_is 'choose retries after abc' "$(printf 'abc\n2\n' | choose Pick RED 'red' GREEN 'green' BLUE 'blue')" 'GREEN'

echo "== choose: EOF must die, not loop =="
_out=$( (choose Pick RED 'red' GREEN 'green' BLUE 'blue' </dev/null) 2>&1 )
case $_out in
*'input ended'*) pass=$((pass+1)); printf '  ok   choose EOF dies\n' ;;
*) fail=$((fail+1)); printf '  FAIL choose EOF: got [%s]\n' "$_out" ;;
esac

echo "== choose: the menu is actually printed =="
_menu=$( (printf '1\n' | choose Pick RED 'alpha' BLUE 'beta') 2>&1 >/dev/null )
for want in 'alpha' 'beta' '1)' '2)'; do
	case $_menu in
	*"$want"*) pass=$((pass+1)); printf '  ok   menu shows %s\n' "$want" ;;
	*) fail=$((fail+1)); printf '  FAIL menu missing %s\n' "$want" ;;
	esac
done

echo "== confirm: only 'yes' proceeds =="
if printf 'yes\n' | confirm Go; then pass=$((pass+1)); printf '  ok   confirm yes\n'; else fail=$((fail+1)); printf '  FAIL confirm yes\n'; fi
if printf 'no\nnope\nyes\n' | confirm Go; then pass=$((pass+1)); printf '  ok   confirm retries\n'; else fail=$((fail+1)); printf '  FAIL confirm retries\n'; fi

echo '== the menu shows labels, never the values =='
_menu=$( (printf '1\n' | choose Pick none 'run from RAM' sys 'install onto a disk') 2>&1 >/dev/null )
for bad in 'none' 'sys'; do
	case $_menu in
	*"$bad"*) fail=$((fail+1)); printf '  FAIL the value [%s] is showing in the menu\n' "$bad" ;;
	*) pass=$((pass+1)); printf '  ok   the value [%s] is not in the menu\n' "$bad" ;;
	esac
done
for good in 'run from RAM' 'install onto a disk'; do
	case $_menu in
	*"$good"*) pass=$((pass+1)); printf '  ok   the label [%s] is shown\n' "$good" ;;
	*) fail=$((fail+1)); printf '  FAIL the label [%s] is missing\n' "$good" ;;
	esac
done
# the chosen value, not the label, is what comes back
ok_is 'the value comes back, not the label' \
	"$(printf '2\n' | choose Pick none 'run from RAM' sys 'install onto a disk')" 'sys'

echo '== an odd number of arguments is an error, not a wild menu =='
_out=$( (printf '1\n' | choose Pick onlyvalue 2>&1 >/dev/null); echo "rc=$?" )
case $_out in
*'odd number'*) pass=$((pass+1)); printf '  ok   reported\n' ;;
*) fail=$((fail+1)); printf '  FAIL not reported: %s\n' "$_out" ;;
esac

# --- the dispatcher, which is where the step names used to be read as answers --
#
# test-ui.sh exercises ui.sh on its own, which is right for ui.sh and is why the
# bug below survived: nothing in this file ran xsetup, so nothing fed a second
# answer to a second step.
#
# That is the whole shape of the failure.  xsetup's step loop read the list of
# steps from stdin:
#
#     done <<EOF
#     $STEPS
#     EOF
#
# and every step's prompts read from stdin.  So the twelve step names were the
# twelve answers.  The first step read "setup-hostname" instead of a keyboard
# layout, and each step after it read the name of the step after that, until the
# list ran out:
#
#     [1/13] setup-keymap
#     Keyboard layout
#       1) us   US English
#       ...
#     choice: warning: 'setup-hostname' is not a number
#     choice: warning: 'setup-interfaces' is not a number
#     ...
#     error: input ended before anything was entered
#
# Every step appeared to run.  Nothing said the answers were wrong, because
# nothing compared them against what was asked for.

# A three-step xsetup whose steps echo the answer they were given.  Not the
# shipped steps: setup-disk writes a partition table and needs a disk, and the
# point here is the dispatcher's stdin, not any one step's work.
DISPATCH_TMP=$(mktemp -d)
trap 'rm -rf "$DISPATCH_TMP"' EXIT INT TERM

mkdir -p "$DISPATCH_TMP/xsetup.d" "$DISPATCH_TMP/lib"
cp "$PWD/lib/ui.sh" "$DISPATCH_TMP/lib/ui.sh"

	# Sourced by absolute path, not by dirname $0: run_step does `. "$_file"` with
	# a path relative to the dispatcher, so the step's own $0 is relative and
	# `dirname $0` from inside it does not name lib/ui.sh.  That fails with "No
	# such file or directory" before the step asks anything - a failure in the
	# harness, not in the dispatcher under test.
	for _s in one two three; do
		{
			echo '#!/bin/sh'
			printf '. %s\n' "$DISPATCH_TMP/lib/ui.sh"
			printf 'ANSWER=$(ask "which answer did %s receive")\n' "$_s"
			printf 'printf "ANSWER=%%s\\n" "$ANSWER"\n'
		} >"$DISPATCH_TMP/xsetup.d/$_s.sh"
	done

# The dispatcher itself, with its step list reduced to those three.
#
# The list opens with `STEPS='setup-keymap` and closes on the last step name
# with a trailing quote - `setup-apkrepos'` - not on a line holding only a
# quote.  Two ways this was got wrong first, both of which produce a dispatcher
# that looks plausible and makes every check below pass or fail for the wrong
# reason: a pattern assuming the opening line is `STEPS='` followed by a newline
# matches nothing and leaves the real thirteen steps in place, and closing on a
# bare quote never matches, so everything after the list is swallowed and
# run_step goes with it.
awk '
	!inlist && /^STEPS='"'"'/ { print "STEPS='"'"'one"; inlist = 1; next }
	inlist && /'"'"'$/ { print "two"; print "three"; print "'"'"'"; inlist = 0; next }
	inlist { next }
	{ print }
' xsetup >"$DISPATCH_TMP/xsetup"

echo '== each step gets its own answer =='
# Three distinct answers for three steps.  With the loop reading its own list
# from stdin these come back as the step names, one behind.
# XSETUP_STATE pointed at a scratch file.  Without it the dispatcher writes to
# /etc/xsetup.state, which this host will not allow, and every step then ends:
#
#     ./xsetup: line 82: /etc/xsetup.state.2704125: Permission denied
#
# The steps still run and still answer correctly, but the dispatcher's own output
# is buried and `grep '^ANSWER='` finds nothing to count - a failure of the
# harness that reads like a failure of the fix.
RUN=$$
D=$(cd "$DISPATCH_TMP" && printf 'alpha\nbravo\ncharlie\n' |
	XSETUP_STATE="$DISPATCH_TMP/state.$RUN" XSETUP_WORK="$DISPATCH_TMP/work" \
	sh ./xsetup 2>&1)

# The answer for a step is on the first ANSWER= line after that step's banner.
# The answer is on the same line as the question, because ui.sh's ask prints its
# prompt without a newline.  So this is a substring match on a line rather than a
# match on a line of its own: `^ANSWER=` never fires, the check finds nothing, and
# three steps that all answered correctly are reported as answering nothing.
answer_for() {
	printf '%s\n' "$D" | awk -v want="$1" '
		/\[[0-9]+\/[0-9]+\]/ { cur = ($0 ~ want "$") }
		cur {
			if (match($0, /ANSWER=[^ ]*/)) { print substr($0, RSTART, RLENGTH); exit }
		}'
}

for pair in 'one:alpha' 'two:bravo' 'three:charlie'; do
	_step=${pair%%:*}
	_want=${pair##*:}
	_got=$(answer_for "$_step")
	ok_is "$_step received $_want" "$_got" "ANSWER=$_want"
done

echo '== the answers are not the step names =='
# The specific way this went wrong, checked on its own.  If any step's answer is
# one of the step names then the loop is still reading its own list from stdin.
_bad=$(printf '%s\n' "$D" | grep -o 'ANSWER=[^ ]*' | sed 's/^ANSWER=//' |
	grep -cE '^(one|two|three)$' || :)
ok_is 'no step answered with a step name' "$_bad" '0'

echo '== every step ran =='
_n=$(printf '%s\n' "$D" | grep -o 'ANSWER=[^ ]*' | wc -l | tr -d ' ')
ok_is 'three steps produced three answers' "$_n" '3'

echo '== a step that fails stops the run =='
# A failing step must not let the next one proceed on a half-configured system,
# and the whole installer must exit non-zero.  `run_ordered; exit 0` threw the
# status away, which is what made a failed run look like a successful one.
#
# Written with heredocs rather than printf: a printf whose format ends in a
# backslash continuation needs that backslash doubled to survive the shell, and
# when it is not the redirection lands after the command has already printed,
# so the step file is written to the test's output and the redirection creates an
# empty file the step then runs.  Both happened here, and both look like the
# dispatcher misbehaving.
cat >"$DISPATCH_TMP/xsetup.d/two.sh" <<EOF
#!/bin/sh
. "$DISPATCH_TMP/lib/ui.sh"
die "two refuses to run"
EOF
cat >"$DISPATCH_TMP/xsetup.d/three.sh" <<EOF
#!/bin/sh
. "$DISPATCH_TMP/lib/ui.sh"
ANSWER=\$(ask "which answer did three receive")
printf 'ANSWER=%s\n' "\$ANSWER"
EOF

RUN=$((RUN + 1))
_rc=$(cd "$DISPATCH_TMP" && printf 'alpha\nbravo\ncharlie\n' |
	XSETUP_STATE="$DISPATCH_TMP/state.$RUN" XSETUP_WORK="$DISPATCH_TMP/work" \
	sh ./xsetup >/dev/null 2>&1; echo $?)
ok_is 'a failing step exits non-zero' "$_rc" '1'
RUN=$((RUN + 1))
_three=$(cd "$DISPATCH_TMP" && printf 'alpha\nbravo\ncharlie\n' |
	XSETUP_STATE="$DISPATCH_TMP/state.$RUN" XSETUP_WORK="$DISPATCH_TMP/work" \
	sh ./xsetup 2>/dev/null | grep -o 'ANSWER=[^ ]*' | wc -l | tr -d ' ')
ok_is 'the step after the failure did not run' "$_three" '1'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
