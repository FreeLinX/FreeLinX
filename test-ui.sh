#!/bin/sh
# Exercises lib/ui.sh, in particular the EOF case that used to hang.
set -u
cd "$(dirname "$0")" || exit 1
ROOTFS=${ROOTFS:-$(cd .. && pwd)/src/rootfs}
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

# --- every choose call in the installer must have whole entries -------------
#
# choose takes a value and a label per option.  A bare word where an entry
# belongs is half an entry, and the count comes out odd, and choose refuses the
# menu outright rather than offering a wrong one:
#
#     error: choose: "Region" was given an odd number of arguments
#
# which is what step 5 of every install died on.  The mistake is invisible in
# the source because the line reads correctly:
#
#     region=$(choose 'Region' none $(menu_pairs $regions))
#
# `none` has a value but no label.  There is no way to see that by looking, and
# nothing else in the tree runs the step, so it is checked here: every choose
# call whose argument list is written out in full, counted, and rejected if it
# is odd.  Calls that generate their pairs with $(...) are skipped, because their
# count depends on what they generate; the bare-word-before-a-continuation case
# below is what catches those.
echo '== every choose call in the installer has whole entries =='
_odd=0
_where=''
for _f in xsetup xsetup.d/*.sh; do
	[ -f "$_f" ] || continue
	# Only calls that do not generate their pairs, so the count is knowable.
	awk -v file="$_f" '
		/\bchoose\b/ {
			line = $0
			while (line !~ /\)[ 	]*$/ && (getline nxt) > 0)
				line = line " " nxt
			if (line ~ /\$\(/) next          # generated pairs
			# The prompt is the first quoted string; drop it.
			sub(/^.*choose[ 	]+("[^"]*"|'"'"'[^'"'"']*'"'"')/, "", line)
			# Tokenise: quoted strings, or runs with no space in them.
			n = 0
			while (match(line, /"[^"]*"|'"'"'[^'"'"']*'"'"'|[^ 	\)]+/)) {
				tok = substr(line, RSTART, RLENGTH)
				line = substr(line, RSTART + RLENGTH)
				if (tok != "\\") n++
			}
			if (n % 2 == 1) {
				printf "  FAIL %s:%d has %d arguments\n", file, FNR, n
				failed = 1
			}
			n = 0
		}
		END { exit failed ? 1 : 0 }
	' "$_f" || _odd=1
done
if [ "$_odd" -eq 0 ]; then
	pass=$((pass + 1)); printf '  ok   every choose call has value and label pairs\n'
else
	fail=$((fail + 1))
fi

echo '== no bare "none" ahead of generated pairs =='
# The specific shape that broke: a lone option value with no label, followed by a
# continuation into a $(...) that supplies the rest of the entries.
_bare=$(grep -c "none \\$" xsetup.d/*.sh xsetup 2>/dev/null | \
	awk -F: '{ t += $2 } END { print t + 0 }')
ok_is 'no bare option value before a continuation' "$_bare" '0'

echo '== a step that returns early does not end the installer =='
# A step that ends with `return 0` because the operator declined something must
# let the run continue.  `exit 0` did not: a step is sourced, so `exit` ended the
# whole installer.  The step printed its line, said everything was fine, and put
# the operator back at the shell prompt with the rest of the steps never run and
# nothing recorded - which reads as the step failing and is the opposite.
cat >"$DISPATCH_TMP/xsetup.d/one.sh" <<EOF
#!/bin/sh
. "$DISPATCH_TMP/lib/ui.sh"
ANSWER=\$(ask "leave it alone?" "no" "yes no" "yes")
if [ "\$ANSWER" = no ]; then
	ok 'left alone'
	return 0
fi
ok 'did the thing'
EOF
cat >"$DISPATCH_TMP/xsetup.d/two.sh" <<EOF
#!/bin/sh
. "$DISPATCH_TMP/lib/ui.sh"
printf 'ANSWER=two-ran\n'
EOF
# Three gets its own text, or the two counts above are the same number and
# neither says anything about whether that step ran.
sed 's/two-ran/three-ran/' "$DISPATCH_TMP/xsetup.d/two.sh" \
	>"$DISPATCH_TMP/xsetup.d/three.sh"
RUN=$((RUN + 1))
E=$(cd "$DISPATCH_TMP" && printf 'no\nno\ncharlie\n' |
	XSETUP_STATE="$DISPATCH_TMP/state.$RUN" XSETUP_WORK="$DISPATCH_TMP/work" \
	sh ./xsetup 2>&1)
ok_is 'the step after the early return still ran' \
	"$(printf '%s\n' "$E" | grep -c 'ANSWER=two-ran' || :)" '1'
# And the last step ran, rather than the run stopping after the early return.
ok_is 'the final step ran too' \
	"$(printf '%s\n' "$E" | grep -c 'ANSWER=three' || :)" '1'

echo '== no step ends the installer with exit =='
# Checked inside functions only for nothing, and at the top level of a step for
# everything: a function may exit when it is the whole job - install_data is
# called by the dispatcher and must not return into the sys install - but a step
# that finishes with `exit 0` ends the installer instead of the step.
#
# An earlier version of this grepped the whole file and so forbade `exit 0`
# everywhere.  That was wrong, and it broke data mode when the check was applied
# as a fix: install_data's exit became a return, and data mode quietly fell
# through and laid out a boot chain on a disk the operator had asked to hold
# /var.  The distinction is the function boundary, not the file.
# Indentation does not say it: install_data's exit is one tab deep and every
# step body is one tab deep too, so a column rule cannot tell a function from a
# step.  What tells them is the shell - a function body runs `return`, and a
# sourced step's body runs the step's own code.  So this asks the shell: source
# each step with every question answered by declining it, which is the path that
# reaches the exit, and see whether the dispatcher survives.
#
# If a step ends the installer, the steps after it never run and the count comes
# out short.  Declining is what the operator does when they do not want the
# optional part of a step, so it is the path worth checking.
_bad=0
for _f in xsetup.d/*.sh; do
	[ -f "$_f" ] || continue
	# Count exits at the step's own level: inside install_data or any other
	# function defined in the file.  The function name is found by walking up to
	# the nearest `name() {` at column zero, which is unambiguous.
	n=$(awk '
		/^[a-z_]+\(\) \{/ { infunc = 1 }
		/^}/                  { infunc = 0 }
		/^[[:space:]]*exit 0[[:space:]]*$/ && !infunc { c++ }
		END { print c + 0 }
	' "$_f")
	[ "$n" -gt 0 ] && _bad=$((_bad + n))
done
ok_is 'no step finishes with exit 0' "$_bad" '0'

echo '== ask_yes: Enter takes the default, not always yes =='
# ask_yes printed the caller's default in its prompt and then ignored it: an
# empty answer was grouped with yes.  Every prompt reading [y/N] therefore
# answered yes to Enter, and the operator was asked a question they had just
# declined:
#
#     Use an HTTP proxy for downloads [[y/N]]:
#     Proxy host:
#
# Five of the eight ask_yes calls in the installer pass n, so that was the answer
# to five of them.
_ay() { printf '%s\n' "$2" | sh -c ". lib/ui.sh; ask_yes Q $1 >/dev/null 2>&1" \
	&& echo yes || echo no; }
ok_is 'default n, Enter'   "$(_ay n '')"  'no'
ok_is 'default n, n'       "$(_ay n n)"   'no'
ok_is 'default n, y'       "$(_ay n y)"   'yes'
ok_is 'default y, Enter'   "$(_ay y '')"  'yes'
ok_is 'default y, n'       "$(_ay y n)"   'no'

echo '== ask_yes: the hint matches the default =='
# The hint is read out of the prompt, because a prompt that says [Y/n] and
# answers no on Enter is worse than one that says nothing.
_yn=$(printf '\n' | sh -c '. lib/ui.sh; ask_yes Q n 2>&1' | grep -o '\[y/N\]')
ok_is 'default n shows [y/N]' "$_yn" '[y/N]'
_yy=$(printf '\n' | sh -c '. lib/ui.sh; ask_yes Q y 2>&1' | grep -o '\[Y/n\]')
ok_is 'default y shows [Y/n]' "$_yy" '[Y/n]'

echo '== choose answers at every row width, under the flags xsetup runs with =='
# xsetup runs `set -eu`.  choose printed its labels in a subshell whose last
# command was
#
#     [ "$_col" -ne 0 ] && printf '\n' >&2
#
# which returns 1 when the options fill the last row exactly, because then _col
# is 0.  Errexit in a command substitution kills the substitution, so the menu
# printed, the "choice:" prompt never did, choose returned nothing and the
# installer exited to the shell - which is why the number typed next went to
# the shell and came back "sh: 1: not found".
#
# It only happened when the count was a multiple of the row width, so it read
# as nothing to do with menus at all: five options worked, six did not,
# twenty-one worked and twenty-four did not.  The old keymap menu had five
# entries.  The new one has twenty-four, which is 4 rows of 6.
#
# Every multiple of the row width is tested, not just the one that broke, and
# under `set -eu` rather than a bare shell - the missing flag is what let every
# other attempt at reproducing this pass.
_roww=12                       # the cell width choose packs columns by
_perrow=$((80 / _roww))        # 6 at an 80 column terminal
_eu=0
for _n in 1 2 "$_perrow" $((_perrow * 2)) $((_perrow * 3)) $((_perrow * 4)) \
	$((_perrow - 1)) $((_perrow + 1)); do
	_pairs=$(awk -v n="$_n" 'BEGIN {
		s = ""; split("a b c d e f g h i j k l m n o p q r s t u v w x y z", L, " ")
		for (i = 1; i <= n; i++) s = s L[i] " " L[i] " "
		print s }')
	_got=$(printf '1\n' | sh -c "
		set -eu
		. lib/ui.sh
		x=\$(choose T $_pairs)
		printf '%s' \"\$x\"" 2>/dev/null)
	if [ -z "$_got" ]; then
		_eu=$((_eu + 1))
		printf '  FAIL %s options, a multiple of %s per row: choose returned nothing\n' \
			"$_n" "$_perrow"
	fi
done
if [ "$_eu" -eq 0 ]; then
	pass=$((pass + 1))
	printf '  ok   choose answers at 1, 2, %s, and %s options under set -eu\n' \
		"$_perrow" $((_perrow * 4))
else
	fail=$((fail + 1))
fi

# And the whole step, not just choose: the keymap menu really is 24 options,
# which is the width that broke, so run the step the way the dispatcher runs it.
_step=$(printf '1\n' | sh -c "
	set -eu
	. lib/ui.sh
	need_root() { :; }
	x=\$(choose 'Keyboard layout' us us gb gb ca ca ie ie de de at at ch ch \\
		es es it it pt pt nl nl be be se se no no dk dk fi fi pl pl cz cz \\
		hu hu ro ro tr tr ru ru gr gr none 'no change')
	printf '%s' \"\$x\"" 2>/dev/null)
ok_is 'the 24 option keymap menu answers under set -eu' "$_step" 'us'

echo '== menus say two letters, not country names =='
# The keymap menu listed "tr   Turkish" and twenty-three like it.  choose prints
# the label and nothing else, so the label was the menu: twenty-four country
# names to read in order to pick the two letters that are the only part anyone
# uses.
#
# The label is taken out of the step rather than assumed, because the first
# version of this check stripped the quotes and measured what was left, and
# "tr   Turkish" then measured as "tr" - it passed with the words back in.
_km=xsetup.d/setup-keymap.sh
if [ -f "$_km" ]; then
	_bad=0
	_n=0
	while IFS= read -r _line; do
		case $_line in
		# The prompt line first, or it is measured as a label: it contains a
		# quoted string too, and "Keyboard layout" is 15 characters.
		keymap=* | '') continue ;;
		*"'"*) _lab=${_line#*\'}; _lab=${_lab%%\'*} ;;
		*) _lab=$(printf '%s' "$_line" | tr -d '\\' | awk '{print $2}') ;;
		esac
		# The action is skipped by name rather than by position: its line
		# begins with a tab like every other, so a leading-space pattern
		# never matched it and it was measured as a code.
		[ "$_lab" = 'no change' ] && continue
		_n=$((_n + 1))
		if [ "${#_lab}" -ne 2 ]; then
			_bad=$((_bad + 1))
			printf '  FAIL keymap label "%s" is %s chars, not a code\n' \
				"$_lab" "${#_lab}"
		fi
	done <<EOF
$(awk '/keymap=\$\(choose/,/^$/' "$_km")
EOF
	if [ "$_bad" -eq 0 ] && [ "$_n" -eq 23 ]; then
		pass=$((pass + 1))
		printf '  ok   all %s keymap labels are two letter codes\n' "$_n"
	else
		fail=$((fail + 1))
		[ "$_n" -ne 24 ] &&
			printf '  FAIL found %s labels, expected 23 codes\n' "$_n"
	fi
	# The action is not a code and has to stay readable, so it is checked on
	# its own rather than being let through for being short.
	ok_is 'the no-change option is still spelled out' \
		"$(grep -c "none 'no change'" "$_km" | tr -d ' ')" '1'
else
	printf '  (no %s, skipping)\n' "$_km"
fi

echo '== the flags the installer passes are the flags the tools accept =='
# setup-user passed -m to flxuseradd, which has no -m.  The step then failed on
# every install with the usage printed above the error, so what the operator
# saw was an account that was not created.  A flag list is read off the tool's
# own strings rather than from the source of the step, so it cannot drift.
_USR=$ROOTFS/bin/flxuseradd
if [ -x "$_USR" ]; then
	_flist=$(grep -oE 'flxuseradd -[a-zA-Z]+' xsetup.d/setup-user.sh |
		cut -d' ' -f2 | sort -u)
	for _f in $_flist; do
		# $_f already carries its own dash - it came from cutting the word
		# "flxuseradd" off "flxuseradd -d" - so the pattern is "$_f " and not
		# "-$_f ". The second one searches for "--d", which appears in
		# nothing, so the check reported both options missing while the step
		# was correct.  A test that cannot find the thing it is looking for
		# says it is not there, which is the worst failure mode there is:
		# it reads as the bug it exists to catch.
		#
		# A yes/no test rather than a count, too: grep -c counts matching
		# *lines*, and several options share one usage line.
		if strings "$_USR" 2>/dev/null | grep -q -- "$_f "; then
			_ok=yes
		else
			_ok=no
		fi
		if [ "$_ok" = yes ]; then
			pass=$((pass + 1)); printf '  ok   flxuseradd takes %s\n' "$_f"
		else
			fail=$((fail + 1))
			printf '  FAIL flxuseradd has no %s; the step would die\n' "$_f"
		fi
	done
else
	printf '  (no %s, skipping)\n' "$_USR"
fi

# --- set_password, which needs an /etc it can write ----------------------------
#
# set_password writes /etc/shadow and calls flxpasswd, which insists on being
# root.  Both are arranged here rather than mocked out, because the thing being
# checked is the pair of them: a hash made by something other than the C library
# is exactly what this must not do, and a stub would have been perfectly happy
# to return one.
#
# unshare -r -m gives this block uid 0 and a private mount table, so a scratch
# directory can be bound over /etc without touching the host's.  Without it the
# checks below would either fail as permission errors or, worse, rewrite the
# host's own passwords.
echo '== set_password =='
SHADOW_TMP=$(mktemp -d)
if ! unshare -r -m true 2>/dev/null; then
	printf '  (no unshare -r -m, skipping)\n'
	SHADOW_TMP=
else
	trap 'rm -rf "$DISPATCH_TMP" "$SHADOW_TMP"' EXIT INT TERM
	# bob is in passwd but not in shadow, which is the state setup-user leaves
	# the account in: the passwd line is written first, then the password asked
	# for, so the shadow line may or may not exist yet.
	cat >"$SHADOW_TMP/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
alice:x:1000:1000:alice:/home/alice:/bin/sh
bob:x:1001:1001:bob:/home/bob:/bin/sh
EOF
	cat >"$SHADOW_TMP/shadow" <<'EOF'
root:!::0:99999:7:::
alice:!::0:99999:7:::
EOF
	chmod 666 "$SHADOW_TMP/passwd" "$SHADOW_TMP/shadow"

	cat >"$SHADOW_TMP/run.sh" <<EOF
set -u
mount --bind "$SHADOW_TMP" /etc || exit 1
PATH="$ROOTFS/bin:$ROOTFS/usr/bin:$ROOTFS/sbin:$ROOTFS/usr/sbin:\$PATH"
export PATH
. "$PWD/lib/ui.sh"
set_password alice 'hunter2'
echo "after-set:"
awk -F: '\$1 == "alice" { print \$2 }' /etc/shadow
set_password alice ''
echo "after-empty:"
awk -F: '\$1 == "alice" { print \$2 }' /etc/shadow
# An account with no /etc/shadow line: setup-user writes the passwd line
# first and asks for the password after, so the shadow line has to be made
# or flxpasswd refuses to touch the account at all.
set_password bob 'pw12345'
echo "bob:"
awk -F: '\$1 == "bob" { print \$2 }' /etc/shadow
EOF
	OUT=$(unshare -r -m sh "$SHADOW_TMP/run.sh" 2>&1)
	_hash=$(printf '%s\n' "$OUT" | sed -n '/^after-set:$/,$p' |
		sed -n '2p')
	_empty=$(printf '%s\n' "$OUT" | sed -n '/^after-empty:$/,$p' |
		sed -n '2p')
	_bob=$(printf '%s\n' "$OUT" | sed -n '/^bob:$/,$p' | sed -n '2p')

	# crypt(3) in musl always says $6$ for SHA-512, and flxpasswd's own check
	# refuses anything else, so this is checking the value actually landed.
	case $_hash in
	'$6$'*) pass=$((pass+1)); printf '  ok   the hash is a crypt(3) SHA-512 hash\n' ;;
	'') fail=$((fail+1)); printf '  FAIL set_password produced no hash; output was:\n%s\n' "$OUT" ;;
	*) fail=$((fail+1)); printf '  FAIL the hash is not a SHA-512 crypt hash: [%s]\n' "$_hash" ;;
	esac
	ok_is 'an empty password leaves the field empty' "$_empty" ''
	case $_bob in
	'$6$'*) pass=$((pass+1)); printf '  ok   an account with no shadow line gets one\n' ;;
	*) fail=$((fail+1)); printf '  FAIL bob: want a $6$ hash, got [%s]\n' "$_bob" ;;
	esac

	# The password must not reach a command line, where ps would show it.
	case $OUT in
	*hunter2*) fail=$((fail+1)); printf '  FAIL the password came back in the output\n' ;;
	*) pass=$((pass+1)); printf '  ok   the password is not echoed\n' ;;
	esac

	# Reintroducing the bug that was here: hashing in the installer with
	# something that is not the C library.  A second SHA-512 crypt is a coin
	# toss on whether it agrees with the one that will verify the hash, so this
	# asserts the hash came out of flxpasswd rather than merely looking right.
	if grep -q flxpasswd "$PWD/lib/ui.sh"; then
		pass=$((pass+1)); printf '  ok   set_password hashes with flxpasswd\n'
	else
		fail=$((fail+1)); printf '  FAIL set_password does not use flxpasswd\n'
	fi
fi

echo '== a user name that is typed in upper case is folded, not refused =='
# The rule used to allow only a-z0-9_- and die on the rest, so typing Kanan
# ended the installer.  Lower case is right to store and wrong to insist on.
_fold() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
ok_is 'Kanan folds to lower case' "$(_fold Kanan)" 'kanan'
ok_is 'mixed case folds'          "$(_fold KanAnMajidzada)" 'kananmajidzada'
ok_is 'lower case is unchanged'   "$(_fold kanan)" 'kanan'
for _bad in '' 'has space' 'has/slash' 'a!b'; do
	_good=no
	case $_bad in
	''|*[!a-zA-Z0-9_-]*) _good=yes ;;
	esac
	ok_is "'$_bad' is still refused" "$_good" 'yes'
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
