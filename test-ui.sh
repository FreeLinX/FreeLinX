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
ok_is 'choose 1'  "$(printf '1\n' | choose Pick RED red green blue)"   'RED'
ok_is 'choose 2'  "$(printf '2\n' | choose Pick RED red green blue)"   'RED'
ok_is 'choose 3'  "$(printf '3\n' | choose Pick RED red green blue)"   'RED'

echo "== choose: single item =="
ok_is 'choose 1 of 1' "$(printf '1\n' | choose Only SOLO 'the only one')" 'SOLO'

echo "== choose: out of range, then valid =="
ok_is 'choose retries after 9' "$(printf '9\n0\n2\n' | choose Pick RED red green blue)" 'RED'

echo "== choose: non-numeric, then valid =="
ok_is 'choose retries after abc' "$(printf 'abc\n2\n' | choose Pick RED red green blue)" 'RED'

echo "== choose: EOF must die, not loop =="
_out=$( (choose Pick RED red green blue </dev/null) 2>&1 )
case $_out in
*'input ended'*) pass=$((pass+1)); printf '  ok   choose EOF dies\n' ;;
*) fail=$((fail+1)); printf '  FAIL choose EOF: got [%s]\n' "$_out" ;;
esac

echo "== choose: the menu is actually printed =="
_menu=$( (printf '1\n' | choose Pick RED alpha beta) 2>&1 >/dev/null )
for want in 'alpha' 'beta' '1)' '2)'; do
	case $_menu in
	*"$want"*) pass=$((pass+1)); printf '  ok   menu shows %s\n' "$want" ;;
	*) fail=$((fail+1)); printf '  FAIL menu missing %s\n' "$want" ;;
	esac
done

echo "== confirm: only 'yes' proceeds =="
if printf 'yes\n' | confirm Go; then pass=$((pass+1)); printf '  ok   confirm yes\n'; else fail=$((fail+1)); printf '  FAIL confirm yes\n'; fi
if printf 'no\nnope\nyes\n' | confirm Go; then pass=$((pass+1)); printf '  ok   confirm retries\n'; else fail=$((fail+1)); printf '  FAIL confirm retries\n'; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
