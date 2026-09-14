#!/bin/sh
# What can be checked without a router.
#
#   ./tests/run-tests.sh           run everything
#   ./tests/run-tests.sh --bless   rewrite the expected replay output from the
#                                  current parser, after capturing new fixtures
#
# Two things are tested, for the two reasons they break:
#
#   fixture replay    the captured feed text through the real parser, diffed
#                     against a checked in expected file. The parser is where
#                     this project will actually break.
#   synthetic buffer  generated event lines through the real fwlive-query,
#                     covering every filter, the cursor arithmetic, the counts
#                     and the output size.
#
# Everything runs under busybox awk and busybox sh when they are installed,
# because that is what the router has and it is stricter than gawk in the ways
# that matter (no gensub, no asort, no time functions, sometimes no ^).

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/package/luci-app-fw-live/files/usr/bin
FIX=$ROOT/tests/fixtures

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Put busybox applets in front, so awk and date behave the way they do on the
# router rather than the way gawk does.
if command -v busybox >/dev/null 2>&1; then
	mkdir -p "$WORK/bin"
	for t in awk date sed sort tr cut wc head grep mv; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$t" > "$WORK/bin/$t"
		chmod 755 "$WORK/bin/$t"
	done
	PATH="$WORK/bin:$PATH"
	export PATH
	RUNSH="busybox sh"
	echo "using busybox applets"
else
	RUNSH="sh"
	echo "busybox not installed, falling back to the system tools"
fi

RUN=$WORK/run
mkdir -p "$RUN"
export FWLIVE_RUN=$RUN

# Pin the clock. The follower stamps events as boot epoch plus uptime, and a
# whole captured feed is read in a few tens of milliseconds, so whether
# /proc/uptime happens to tick over partway through decides whether the rate
# limiter gives the tail of a flood a fresh budget. Real behaviour, and about
# one run in twenty it made the test for that behaviour fail.
printf '12345.67 98765.43\n' > "$WORK/uptime"
export FWLIVE_UPTIME=$WORK/uptime

PASS=0
FAIL=0
SKIP=0

ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $1"; }

check() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi
}

# The first value of a numeric JSON field. Every scalar this checks is emitted
# before the event array, so first-match is the right one.
jnum() {
	sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" "$1" | head -n 1
}

jbool() {
	sed -n "s/.*\"$2\":\(true\|false\).*/\1/p" "$1" | head -n 1
}

nevents() {
	grep -o '"id":"' "$1" | wc -l | tr -d ' '
}

parse() {
	# $1 = log | ct, $2 = input file
	FWLIVE_BOOT=1757660000 $RUNSH "$BIN/fwlive-follow" --parse "$1" < "$2"
}

BLESS=0
[ "$1" = "--bless" ] && BLESS=1

flood() {
	# $1 count, $2 out file
	awk -v n="$1" 'BEGIN {
		for (i = 1; i <= n; i++)
			printf "    [NEW] tcp      6 120 SYN_SENT src=10.0.0.%d dst=203.0.113.9 sport=%d dport=443\n",
				(i % 250) + 1, 20000 + i
	}' > "$2"
}

query() {
	$RUNSH "$BIN/fwlive-query" "$@" > "$WORK/out.json"
}

# The timestamp is stamped at read time by design, so it is the one column
# that cannot be reproduced. Everything else must match exactly.
strip_ts() {
	awk 'BEGIN { FS = OFS = "\t" } { $1 = "T"; print }' "$1"
}

# Each case is a set of captured feed text plus the local prefixes that were
# in force when it was captured, because the direction column is a function of
# both. router is the real thing off the target hardware; synthetic covers what
# a single capture window happened not to contain.
CASES="router namedrule chained synthetic"

replay_case() {
	_case=$1
	_den=$FIX/$_case-denies.txt
	_acc=$FIX/$_case-conntrack.txt
	_sub=$FIX/$_case-subnets

	for _f in "$_den" "$_acc" "$_sub"; do
		[ -f "$_f" ] && continue
		skip "$_case: ${_f##*/} is missing, so this capture is not being replayed"
		return 0
	done

	cp "$_sub" "$RUN/subnets"
	rm -f "$RUN/events.log" "$RUN/events.ct" "$RUN/stats.log" "$RUN/stats.ct"
	# No rate limit here: a whole capture arrives in one second when it is
	# read from a file, and shedding it would test nothing.
	FWLIVE_MAX_RATE=0 parse log "$_den"
	FWLIVE_MAX_RATE=0 parse ct "$_acc"

	if [ "$BLESS" = 1 ]; then
		strip_ts "$RUN/events.log" > "$FIX/expected-$_case-log.tsv"
		strip_ts "$RUN/events.ct" > "$FIX/expected-$_case-ct.tsv"
		echo "  blessed $_case: $(wc -l < "$FIX/expected-$_case-log.tsv" | tr -d ' ') denied, $(wc -l < "$FIX/expected-$_case-ct.tsv" | tr -d ' ') accepted"
		return 0
	fi

	for _feed in log ct; do
		_want=$FIX/expected-$_case-$_feed.tsv
		if [ ! -f "$_want" ]; then
			skip "$_case: expected-$_case-$_feed.tsv is missing, run --bless"
			continue
		fi
		strip_ts "$RUN/events.$_feed" > "$WORK/got.tsv"
		if diff -u "$_want" "$WORK/got.tsv" > "$WORK/diff"; then
			_what=$([ "$_feed" = log ] && echo "denied packets" || echo "accepted connections")
			ok "$_case: $_what parse to the expected event lines"
		else
			bad "$_case: the $_feed feed"
			head -40 "$WORK/diff"
		fi
	done

	# Every event must have exactly the 15 columns the record is defined as,
	# with no empty field anywhere: an empty trailing field would be lost.
	_bad=$(awk -F'\t' 'NF != 15 { n++ } { for (i = 1; i <= NF; i++) if ($i == "") n++ } END { print n + 0 }' \
		"$RUN/events.log" "$RUN/events.ct")
	check "$_case: every event has 15 non-empty columns" "$_bad" "0"

	# Nothing may be dropped on the floor. Every input line that carries the
	# marker the feed is selected on has to come out as an event.
	# Counted with awk rather than grep -c: grep exits 1 on no match, so the
	# usual "|| echo 0" appends a second zero to the count it already printed.
	_inden=$(awk '/ IN=/ { n++ } END { print n + 0 }' "$_den")
	_inacc=$(awk '/^ *\[NEW\]/ { n++ } END { print n + 0 }' "$_acc")
	# Two lines can become one row, so what has to hold is that every line is
	# accounted for, as an event or as a merge into one.
	_merged=$(awk '$1 == "merged" { print $2 + 0 }' "$RUN/stats.log")
	case "$_merged" in ''|*[!0-9]*) _merged=0 ;; esac
	check "$_case: every logged packet became an event or was merged into one" \
		"$(( $(wc -l < "$RUN/events.log" | tr -d ' ') + _merged ))" "$_inden"
	check "$_case: every NEW conntrack event became an event" \
		"$(wc -l < "$RUN/events.ct" | tr -d ' ')" "$_inacc"
}

echo
echo "source constraints"

# The awk parser lives in a single quoted shell variable, so one apostrophe
# anywhere inside it ends the string and the script dies at a line number that
# points nowhere near the real problem. sh -n catches it only when the damage
# happens to be a syntax error, which it usually is not.
#
# \047 is the apostrophe, spelled so this check does not have to contain one
# either. The end of the block is a line that is exactly that and nothing
# else; matching any one character line would stop at the first closing brace.
_apos=$(awk '
	$0 == "PARSER=\047" { inside = 1; next }
	inside && $0 == "\047" { inside = 0; next }
	inside { seen++; if (index($0, "\047") > 0) print "    line " FNR ": " $0 }
	END { if (seen < 100) print "    the parser block was not found, this check is not checking anything" }
' "$BIN/fwlive-follow")
if [ -z "$_apos" ]; then
	ok "the parser contains no apostrophe to end its own quoting"
else
	bad "apostrophes inside the single quoted parser"
	echo "$_apos"
fi

# ucode drops the backslash from a \] inside a bracket expression, so the
# escaped spelling closes the class early and leaves a pattern that matches
# nothing. A literal closing bracket has to be written first instead. This is
# silent: the regex still compiles, it just never matches, and the ucode
# backend is the one file that cannot be exercised off a router.
_brk=$(awk '
	{
		line = $0
		while (match(line, /\[[^]]*\\\]/)) {
			print "    line " FNR ": " $0
			line = substr(line, RSTART + RLENGTH)
		}
	}
' "$ROOT/package/luci-app-fw-live/files/usr/share/rpcd/ucode/luci.fw_live.uc")
if [ -z "$_brk" ]; then
	ok "no escaped closing bracket inside a ucode bracket expression"
else
	bad "escaped closing brackets in the ucode backend, which match nothing"
	echo "$_brk"
fi

echo
echo "fixture replay"

for c in $CASES; do
	replay_case "$c"
done

if [ "$BLESS" = 1 ]; then
	echo
	echo "expected files rewritten from the current parser; read the diff before committing"
	exit 0
fi

# Asserted against the blessed file on purpose. The replay above already
# compares parser output to it, so this adds nothing about the parser; what it
# catches is a careless --bless quietly rewriting the one rule that is easy to
# get wrong. A rule logged under its own name says nothing about what happened
# to the packet, and guessing drop would put a red chip on accepted traffic.
check "a prefix with no verdict word is recorded as unknown, not guessed at" \
	"$(awk -F'\t' '$14 == "Block-Guest-To-LAN" { print $4 }' "$FIX/expected-synthetic-log.tsv")" \
	"unknown"
# Ground truth from the router this capture came off. Block-Internet does
# not decide these packets: it logs them on the way past and something further
# down does. So one rule name appears on traffic that was allowed through to a
# local resolver and on traffic that was then refused, and the log lines differ
# in nothing that could tell them apart. This is what makes "unknown" the
# honest answer rather than a fallback, so it is asserted rather than
# described.
# One broadcast flooded to four bridge ports. Without PHYSIN and PHYSOUT these
# four rows are identical in all fifteen columns and the view shows four lines
# with nothing to say why.
check "a broadcast flooded to four ports gives four distinguishable rows" \
	"$(awk -F'\t' '$8 == "60537" { print $12 }' "$FIX/expected-namedrule-log.tsv" | sort -u | wc -l | tr -d ' ')" \
	"4"
check "the bridge port a packet arrived on is kept" \
	"$(awk -F'\t' '$8 == "60537" { print $11 }' "$FIX/expected-namedrule-log.tsv" | sort -u)" \
	"br-lan/wlan0"

# The merge: the same packet logged by the rule it matched and again by the
# chain that refused it becomes one row with both facts on it.
check "a rule name and the verdict for the same packet become one row" \
	"$(awk -F'\t' '$8 == "46446" { print $4, $14 }' "$FIX/expected-namedrule-log.tsv")" \
	"reject Block-Internet"
check "and it is one row, not two" \
	"$(awk -F'\t' '$8 == "46446"' "$FIX/expected-namedrule-log.tsv" | wc -l | tr -d ' ')" "1"
check "a packet nothing else decided keeps its unknown verdict" \
	"$(awk -F'\t' '$9 == "192.168.30.20" { print $4 }' "$FIX/expected-namedrule-log.tsv" | sort -u)" \
	"unknown"
check "the whole capture still accounts for every line" \
	"$(wc -l < "$FIX/expected-namedrule-log.tsv" | tr -d ' ')" "16"

# A packet can match more than one rule that logs. That is still one packet,
# so it is one row, and the rule column becomes the path it took.
check "two rules logging one packet give one row naming both" \
	"$(awk -F'\t' '$8 == "53578" { print $14 }' "$FIX/expected-chained-log.tsv")" \
	"Block-Internet > Block-DNS2"
check "which is one row, not two" \
	"$(awk -F'\t' '$8 == "53578"' "$FIX/expected-chained-log.tsv" | wc -l | tr -d ' ')" "1"

# The trap in the line above: a multicast flooded to four bridge ports shares
# an IP ID and a five tuple across all four copies. They are four forwarding
# decisions, not one packet logged four times, and chaining them into one row
# would quietly lose three of them.
check "four copies of one multicast stay four rows" \
	"$(awk -F'\t' '$9 == "239.255.255.250"' "$FIX/expected-chained-log.tsv" | wc -l | tr -d ' ')" "4"
check "each naming only the single rule that logged it" \
	"$(awk -F'\t' '$9 == "239.255.255.250" { print $14 }' "$FIX/expected-chained-log.tsv" | sort -u)" \
	"Block-Internet"
check "and still distinguishable by the port they went out of" \
	"$(awk -F'\t' '$9 == "239.255.255.250" { print $12 }' "$FIX/expected-chained-log.tsv" | sort -u | wc -l | tr -d ' ')" "4"

check "a prefix that does say drop is still a drop" \
	"$(awk -F'\t' '$14 == "drop wan invalid ct state" { print $4 }' "$FIX/expected-synthetic-log.tsv")" \
	"drop"

cp "$FIX/synthetic-subnets" "$RUN/subnets"

echo
echo "rate limit"

# A whole flood arrives inside one second, which is exactly the case the rate
# limit exists for: past max_rate the excess is counted and dropped.
rm -f "$RUN/events.ct" "$RUN/stats.ct"
flood 700 "$WORK/flood.txt"
FWLIVE_MAX_RATE=200 parse ct "$WORK/flood.txt"
check "events past max_rate in one second are not written" \
	"$(wc -l < "$RUN/events.ct" | tr -d ' ')" "200"
check "and are counted as shed" \
	"$(awk '$1 == "shed" { print $2 }' "$RUN/stats.ct")" "500"

rm -f "$RUN/events.ct" "$RUN/stats.ct"
FWLIVE_MAX_RATE=0 parse ct "$WORK/flood.txt"
check "max_rate 0 means no limit" \
	"$(wc -l < "$RUN/events.ct" | tr -d ' ')" "700"

echo
echo "buffer trim"

rm -f "$RUN/events.ct" "$RUN/stats.ct"
flood 1000 "$WORK/flood.txt"
FWLIVE_MAX_RATE=0 FWLIVE_BUFFER_SIZE=300 parse ct "$WORK/flood.txt"
KEPT=$(wc -l < "$RUN/events.ct" | tr -d ' ')
TRIMMED=$(awk '$1 == "trimmed" { print $2 }' "$RUN/stats.ct")
check "the spool is trimmed to buffer_size" "$KEPT" "300"
check "discarded events are counted" "$TRIMMED" "700"
check "the oldest kept event is the right one" \
	"$(head -n 1 "$RUN/events.ct" | cut -f2)" "701"
check "the newest kept event is the last one in" \
	"$(tail -n 1 "$RUN/events.ct" | cut -f2)" "1000"
check "nothing is lost or duplicated" "$((KEPT + TRIMMED))" "1000"

echo
echo "merge_rules off"

rm -f "$RUN/events.log" "$RUN/stats.log"
cp "$FIX/namedrule-subnets" "$RUN/subnets"
FWLIVE_MAX_RATE=0 FWLIVE_MERGE_RULES=0 parse log "$FIX/namedrule-denies.txt"
check "with merging off every line is its own event again" \
	"$(wc -l < "$RUN/events.log" | tr -d ' ')" "20"
check "and the rule line keeps its unknown verdict" \
	"$(awk -F'\t' '$8 == "46446" { print $4 }' "$RUN/events.log" | tr '\n' ' ')" \
	"unknown reject "
check "nothing is merged" \
	"$(awk '$1 == "merged" { print $2 }' "$RUN/stats.log")" "0"

# What the raw log actually contains, which is what the merge exists to fix:
# one rule name over packets with different outcomes, and the same packet
# logged twice under two prefixes.
check "raw, one rule name covers packets with different outcomes" \
	"$(awk -F'\t' '$14 == "Block-Internet" { print $4 }' "$RUN/events.log" | sort -u | tr '\n' ' ')" \
	"unknown "
check "raw, the rule that refuses it logs the same packet again" \
	"$(awk -F'\t' '$8 == "46446" { print $14 }' "$RUN/events.log" | tr '\n' ' ')" \
	"Block-Internet reject wan out "

# The tick is how a held event gets out on a quiet log. It must never become
# an event of its own.
rm -f "$RUN/events.log" "$RUN/stats.log"
{ head -2 "$FIX/namedrule-denies.txt"; echo "__fwlive_tick__"; } > "$WORK/ticked.txt"
FWLIVE_MAX_RATE=0 parse log "$WORK/ticked.txt"
check "a tick releases a held event without becoming one" \
	"$(wc -l < "$RUN/events.log" | tr -d ' ')" "2"
check "and no event came from the tick itself" \
	"$(grep -c "fwlive_tick" "$RUN/events.log" | tr -d ' ')" "0"

cp "$FIX/synthetic-subnets" "$RUN/subnets"

echo
echo "ignore_unknown"

# Their own capture is the case this exists for: a rule that logs but does not
# decide. With it on, the events it produced go away and the rule that really
# refused the packet still reports it.
rm -f "$RUN/events.log" "$RUN/stats.log"
cp "$FIX/namedrule-subnets" "$RUN/subnets"
FWLIVE_MAX_RATE=0 FWLIVE_IGNORE_UNKNOWN=1 parse log "$FIX/namedrule-denies.txt"
check "events with no verdict in the prefix are not captured" \
	"$(awk -F'\t' '$4 == "unknown"' "$RUN/events.log" | wc -l | tr -d ' ')" "0"
check "and the rule that did refuse the packet still reports it" \
	"$(awk -F'\t' '$4 == "reject"' "$RUN/events.log" | wc -l | tr -d ' ')" \
	"$(awk -F'\t' '$4 == "reject"' "$FIX/expected-namedrule-log.tsv" | wc -l | tr -d ' ')"
check "nothing else is lost" \
	"$(wc -l < "$RUN/events.log" | tr -d ' ')" \
	"$(awk -F'\t' '$4 != "unknown"' "$FIX/expected-namedrule-log.tsv" | wc -l | tr -d ' ')"
check "the sequence numbers stay contiguous" \
	"$(cut -f2 "$RUN/events.log" | tr '\n' ' ')" "1 2 3 4 5 6 "

cp "$FIX/synthetic-subnets" "$RUN/subnets"

echo
echo "ignore_local"

rm -f "$RUN/events.ct" "$RUN/stats.ct"
FWLIVE_IGNORE_LOCAL=1 parse ct "$FIX/synthetic-conntrack.txt"
check "events with both ends on a local network are left out" \
	"$(awk -F'\t' '$13 == "local"' "$RUN/events.ct" | wc -l | tr -d ' ')" "0"
check "everything else still arrives" \
	"$(wc -l < "$RUN/events.ct" | tr -d ' ')" \
	"$(awk -F'\t' '$13 != "local"' "$FIX/expected-synthetic-ct.tsv" | wc -l | tr -d ' ')"

echo
echo "service lifecycle"

# The one part of this that is about processes rather than parsing, and the
# part that went wrong in the most confusing way: a follower that is asked to
# stop has to take its readers and parsers with it, and a follower that was
# killed outright leaves them behind for the next start to sweep up. Getting
# this wrong leaks a logread per restart, which nothing in the page reveals.
if command -v pgrep >/dev/null 2>&1 && command -v conntrack >/dev/null 2>&1; then
	skip "service lifecycle: a real conntrack is on this machine, not stubbing over it"
elif ! command -v pgrep >/dev/null 2>&1; then
	skip "service lifecycle: pgrep is not installed"
else
	LIFE=$WORK/life
	mkdir -p "$LIFE/bin" "$LIFE/run" "$LIFE/sbin"
	cp "$FIX/router-subnets" "$LIFE/run/subnets"
	cp "$BIN/fwlive-follow" "$LIFE/sbin/fwlive-follow"
	for _feed in logread conntrack; do
		printf '#!/bin/sh\ncat %s\nexec sleep 100000\n' "$FIX/namedrule-denies.txt" > "$LIFE/bin/$_feed"
		chmod 755 "$LIFE/bin/$_feed"
	done

	mine() { pgrep -f "$LIFE" 2>/dev/null | grep -c . | tr -d ' '; }
	# Started inside a subshell so this shell does not adopt it as a job and
	# announce it when the kill -9 below lands.
	launch() {
		( PATH="$LIFE/bin:$PATH" FWLIVE_RUN=$LIFE/run \
			$RUNSH "$LIFE/sbin/fwlive-follow" >/dev/null 2>&1 &
		  echo $! > "$LIFE/main.pid" )
	}

	launch
	sleep 2
	_up=$(mine)
	if [ "$_up" -lt 3 ]; then
		bad "the service starts a reader and a parser per feed (saw $_up processes)"
	else
		ok "the service starts a reader and a parser per feed"
	fi

	kill -TERM "$(cat "$LIFE/main.pid")" 2>/dev/null
	sleep 2
	check "asking it to stop takes everything with it" "$(mine)" "0"

	# Killed outright, so nothing of its own can clean up after it.
	launch
	sleep 2
	kill -9 "$(cat "$LIFE/main.pid")" 2>/dev/null
	sleep 1
	_orphans=$(mine)
	if [ "$_orphans" -gt 0 ]; then
		ok "killing it outright does leave processes behind ($_orphans)"
	else
		bad "expected orphans after a kill -9, saw none, so the next check proves nothing"
	fi

	launch
	sleep 3
	_after=$(mine)
	kill -TERM "$(cat "$LIFE/main.pid")" 2>/dev/null
	sleep 2
	check "the next start sweeps them up rather than stacking on top" \
		"$_after" "$_up"
	check "and that start stops cleanly too" "$(mine)" "0"
fi

echo
echo "firewall logging"

# fwlive-logging is the one thing in the package that writes the firewall
# config, so it gets a uci to write to rather than being taken on trust.
# Matching is literal, because a section id like @rule[3] is not a regex.
FWDIR=$WORK/fw
mkdir -p "$FWDIR/bin"
cat > "$FWDIR/bin/uci" <<'UCISTUB'
#!/bin/sh
F=$FAKE_UCI
while [ "$1" = "-q" ]; do shift; done
case "$1" in
	show)    cat "$F" ;;
	get)     awk -v k="$2=" 'index($0, k) == 1 { sub(/^[^=]*=/, "", $0); gsub(/^\047|\047$/, "", $0); print; f = 1; exit } END { exit !f }' "$F" ;;
	set)     k=${2%%=*}; v=${2#*=}
	         awk -v k="$k=" 'index($0, k) != 1' "$F" > "$F.n"
	         printf "%s='%s'\n" "$k" "$v" >> "$F.n"; mv "$F.n" "$F" ;;
	delete)  awk -v k="$2=" 'index($0, k) != 1' "$F" > "$F.n"; mv "$F.n" "$F" ;;
	commit|changes|revert) : ;;
	*)       exit 1 ;;
esac
exit 0
UCISTUB
cat > "$FWDIR/bin/firewall-init" <<'FWINIT'
#!/bin/sh
echo "$1" >> "$FW_RELOADS"
exit 0
FWINIT
chmod 755 "$FWDIR/bin/uci" "$FWDIR/bin/firewall-init"

FW_RELOADS=$FWDIR/reloads
export FW_RELOADS
fwlog() {
	PATH="$FWDIR/bin:$PATH" FAKE_UCI=$FWDIR/config FWLIVE_FW_INIT=$FWDIR/bin/firewall-init \
		$RUNSH "$BIN/fwlive-logging" "$@"
}

cp "$FIX/firewall-config" "$FWDIR/config"
: > "$FW_RELOADS"

fwlog --list > "$WORK/fw.json"
if command -v python3 >/dev/null 2>&1; then
	if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/fw.json"; then
		ok "the firewall listing parses as JSON"
	else
		bad "the firewall listing parses as JSON"
	fi
fi
check "named and anonymous zones are both listed" \
	"$(grep -o '"sect":"[^"]*"' "$WORK/fw.json" | head -3 | tr '\n' ' ')" \
	'"sect":"@zone[0]" "sect":"@zone[1]" "sect":"iot" '
check "a rule that refuses traffic is marked as one" \
	"$(sed -n 's/.*"name":"Block-SMB-Out"[^}]*"denies":\(true\|false\).*/\1/p' "$WORK/fw.json")" "true"
check "a rule that only marks is not" \
	"$(sed -n 's/.*"name":"Block-Internet"[^}]*"denies":\(true\|false\).*/\1/p' "$WORK/fw.json")" "false"

fwlog --set '@rule[1]=1' 'blocksmb=1' > "$WORK/fw.set"
check "logging is turned on for both, named and anonymous" \
	"$(sed -n 's/.*"changed":\([0-9]*\).*/\1/p' "$WORK/fw.set")" "2"
check "and the firewall was reloaded once" "$(wc -l < "$FW_RELOADS" | tr -d ' ')" "1"
# three were already set in the fixture, plus the two just turned on
check "the option really is in the config" \
	"$(grep -c "\.log='1'" "$FWDIR/config" | tr -d ' ')" "5"

fwlog --set '@rule[1]=1' 'blocksmb=1' > "$WORK/fw.set"
check "setting what is already set changes nothing" \
	"$(sed -n 's/.*"changed":\([0-9]*\).*/\1/p' "$WORK/fw.set")" "0"
check "and does not reload the firewall again" "$(wc -l < "$FW_RELOADS" | tr -d ' ')" "1"

fwlog --set '@rule[1]=0' > "$WORK/fw.set"
check "turning it off removes the option rather than setting it to zero" \
	"$(grep -c "@rule\[1\].log" "$FWDIR/config" | tr -d ' ')" "0"

# Everything below must be refused. This is the only call in the package that
# writes outside its own config, so it is the only one worth attacking.
for _bad in "nosuchsection=1" "@zone[0]=7" "a;id=1" "\$(id)=1" "\`id\`=1" "../../etc/passwd=1" "@rule[0]=1x"; do
	_before=$(cat "$FWDIR/config")
	fwlog --set "$_bad" > "$WORK/fw.set" 2>&1
	if [ "$_before" = "$(cat "$FWDIR/config")" ]; then
		ok "refused: $_bad"
	else
		bad "refused: $_bad, but the config changed"
	fi
done

# An ACCEPT rule is a legitimate target: naming accepted traffic is the whole
# point of per rule logging. Only nonsense is refused, not unusual choices.
fwlog --set '@rule[0]=1' > "$WORK/fw.set"
check "an accept rule can be logged too" \
	"$(sed -n 's/.*"changed":\([0-9]*\).*/\1/p' "$WORK/fw.set")" "1"

echo
echo "resolving a verdictless event against the accepted feed"

# A rule can log a packet under its own name and never say what became of it.
# A conntrack entry is proof the packet was allowed through; no entry is not
# proof of anything, because the feed could be off or the event trimmed.
RV=$WORK/rv
mkdir -p "$RV"
_now=$(date +%s)
{
	printf '%s\t1\tlog\tunknown\t4\tudp\t10.0.0.1\t33758\t239.255.255.250\t15600\tbr0\tbr0\tlocal\tNamedRule\t-\n' "$_now"
	printf '%s\t2\tlog\tunknown\t4\tudp\t10.0.0.1\t53578\t10.0.30.20\t53\tbr0\tmac0\tlocal\tNamedRule\t-\n' "$_now"
	printf '%s\t3\tlog\tunknown\t4\tudp\t10.0.0.1\t44444\t10.0.30.20\t53\tbr0\tmac0\tlocal\tNamedRule\t-\n' "$((_now - 600))"
	printf '%s\t4\tlog\treject\t4\ttcp\t10.0.0.1\t55555\t10.0.30.20\t80\tbr0\tmac0\tlocal\treject wan out\tSYN\n' "$_now"
} > "$RV/events.log"
{
	printf '%s\t1\tct\taccept\t4\tudp\t10.0.0.1\t33758\t239.255.255.250\t15600\t-\t-\tlocal\t-\t-\n' "$_now"
	printf '%s\t2\tct\taccept\t4\tudp\t10.0.0.1\t44444\t10.0.30.20\t53\t-\t-\tlocal\t-\t-\n' "$_now"
	printf '%s\t3\tct\taccept\t4\ttcp\t10.0.0.1\t55555\t10.0.30.20\t80\t-\t-\tlocal\t-\t-\n' "$_now"
} > "$RV/events.ct"

FWLIVE_RUN=$RV $RUNSH "$BIN/fwlive-query" 20 0 0 "" "" "" "" > "$WORK/rv.json"
rvverdict() {
	sed -n "s/.*\"id\":\"log:$1\",\"verdict\":\"\([a-z]*\)\".*/\1/p" "$WORK/rv.json"
}
check "a matching conntrack event proves the packet was allowed" "$(rvverdict 1)" "accept"
check "and the rule name survives being resolved" \
	"$(sed -n 's/.*"id":"log:1".*"rule":"\([^"]*\)".*/\1/p' "$WORK/rv.json")" "NamedRule"
check "no conntrack event leaves it unknown rather than guessing a refusal" \
	"$(rvverdict 2)" "unknown"
# the same five tuple ten minutes later is a different flow, not this one
check "a conntrack event too far away in time does not count" "$(rvverdict 3)" "unknown"
check "an event that already had a verdict keeps it" "$(rvverdict 4)" "reject"
check "and the resolved count says how many were recovered" \
	"$(sed -n 's/.*"resolved":\([0-9]*\).*/\1/p' "$WORK/rv.json")" "1"
check "counts follow the resolution" \
	"$(sed -n 's/.*\("counts":{[^}]*}\).*/\1/p' "$WORK/rv.json")" \
	'"counts":{"accept":3,"drop":0,"reject":1,"unknown":2}'

# The log half is the one row the connection gets: it is the half that carries
# the rule name and the bridge port. The conntrack events that resolved nothing
# are events in their own right and stay.
rvhas() {
	grep -c "\"id\":\"$1\"" "$WORK/rv.json"
}
check "the conntrack event that resolved a log event is not also a row of its own" \
	"$(rvhas ct:1)" "0"
check "one that resolved nothing still is" "$(rvhas ct:2)" "1"
check "and so is one whose log event already had a verdict" "$(rvhas ct:3)" "1"

echo
echo "synthetic buffer"

# Two feeds whose timestamps overlap, so the merge has to interleave them
# rather than concatenate.
gen() {
	# $1 src, $2 count, $3 base ts, $4 events per second, $5 out
	awk -v src="$1" -v n="$2" -v base="$3" -v rate="$4" 'BEGIN {
		OFS = "\t"
		split("tcp udp icmp", P, " ")
		split("in out local", D, " ")
		for (i = 1; i <= n; i++) {
			ts = base + int((i - 1) / rate)
			if (src == "ct") { v = "accept"; rule = "-"; iif = "-" }
			else { v = (i % 2) ? "reject" : "drop"; rule = v " wan in"; iif = "eth1" }
			print ts, i, src, v, 4, P[1 + (i % 3)], \
			      "10.0.0." ((i % 250) + 1), 1024 + i, \
			      "203.0.113." ((i % 200) + 1), (i % 1000) + 1, \
			      iif, "-", D[1 + (i % 3)], rule, "-"
		}
	}' > "$5"
}

rm -f "$RUN/stats.log" "$RUN/stats.ct"
gen log 300 1757660000 2 "$RUN/events.log"
gen ct 700 1757660000 5 "$RUN/events.ct"

# What the generated buffer actually holds, worked out from the files rather
# than hardcoded, so these stay honest if the generator changes.
tot() { awk -F'\t' "$1" "$RUN/events.log" "$RUN/events.ct" | wc -l | tr -d ' '; }
N_ALL=$(tot '{ print }')
N_ACCEPT=$(tot '$4 == "accept"')
N_DROP=$(tot '$4 == "drop"')
N_REJECT=$(tot '$4 == "reject"')
N_UDP=$(tot '$6 == "udp"')
N_IN=$(tot '$13 == "in"')
N_SEARCH=$(tot '$7 == "10.0.0.42"')

query 200 0 0 "" "" "" ""
check "a full page is capped at the limit" "$(nevents "$WORK/out.json")" "200"
check "truncated says there was more" "$(jbool "$WORK/out.json" truncated)" "true"
check "matched counts every matching event" "$(jnum "$WORK/out.json" matched)" "$N_ALL"
check "accept count is over the whole buffer" "$(jnum "$WORK/out.json" accept)" "$N_ACCEPT"
check "drop count is over the whole buffer" "$(jnum "$WORK/out.json" drop)" "$N_DROP"
check "reject count is over the whole buffer" "$(jnum "$WORK/out.json" reject)" "$N_REJECT"
check "the log high water mark is the last seq" "$(jnum "$WORK/out.json" log)" "300"
check "the ct high water mark is the last seq" "$(jnum "$WORK/out.json" ct)" "700"

TS_ORDER=$(grep -o '"ts":[0-9]*' "$WORK/out.json" | cut -d: -f2 |
	awk 'NR > 1 && $1 > prev { bad++ } { prev = $1 } END { print bad + 0 }')
check "events come back newest first across both feeds" "$TS_ORDER" "0"

MIXED=$(grep -o '"id":"ct:' "$WORK/out.json" | wc -l | tr -d ' ')
if [ "$MIXED" -gt 0 ] && [ "$MIXED" -lt 200 ]; then
	ok "the page holds events from both feeds"
else
	bad "the page holds events from both feeds: $MIXED of 200 are conntrack"
fi

query 1000 0 0 "drop" "" "" ""
check "verdict filter returns only that verdict" \
	"$(grep -o '"verdict":"[a-z]*"' "$WORK/out.json" | sort -u | tr -d '\n')" \
	'"verdict":"drop"'
check "verdict filter matched count" "$(jnum "$WORK/out.json" matched)" "$N_DROP"
check "counts ignore the filter" "$(jnum "$WORK/out.json" accept)" "$N_ACCEPT"

query 1000 0 0 "drop,reject" "" "" ""
check "a multi verdict filter matches the union" \
	"$(jnum "$WORK/out.json" matched)" "$((N_DROP + N_REJECT))"

query 1000 0 0 "none" "" "" ""
check "asking for no verdict at all matches nothing" "$(nevents "$WORK/out.json")" "0"

check "counts carry every verdict the record can hold" \
	"$(sed -n 's/.*\("counts":{[^}]*}\).*/\1/p' "$WORK/out.json")" \
	"\"counts\":{\"accept\":$N_ACCEPT,\"drop\":$N_DROP,\"reject\":$N_REJECT,\"unknown\":0}"

query 1000 0 0 "" "udp" "" ""
check "protocol filter" "$(jnum "$WORK/out.json" matched)" "$N_UDP"

query 1000 0 0 "" "" "in" ""
check "direction filter" "$(jnum "$WORK/out.json" matched)" "$N_IN"

query 1000 0 0 "" "" "" "10.0.0.42"
check "search filter" "$(jnum "$WORK/out.json" matched)" "$N_SEARCH"

query 1000 0 0 "" "udp" "in" "10.0.0.42"
COMBO=$(tot '$6 == "udp" && $13 == "in" && $7 == "10.0.0.42"')
check "filters combine" "$(jnum "$WORK/out.json" matched)" "$COMBO"

query 200 300 700 "" "" "" ""
check "a cursor at the head returns nothing" "$(nevents "$WORK/out.json")" "0"
check "and still reports the counts" "$(jnum "$WORK/out.json" accept)" "$N_ACCEPT"

query 200 297 698 "" "" "" ""
check "a cursor behind the head returns only what is new" \
	"$(nevents "$WORK/out.json")" "5"
check "the newest event is still first" \
	"$(sed -n 's/.*"events":\[{"ts":[0-9]*,"id":"\([a-z]*:[0-9]*\)".*/\1/p' "$WORK/out.json")" \
	"log:300"

query 5000 0 0 "" "" "" ""
check "the limit is clamped to 1000" "$(nevents "$WORK/out.json")" "1000"

query 0 0 0 "" "" "" ""
check "a zero limit falls back to the default" "$(nevents "$WORK/out.json")" "200"

query 200 0 0 "; rm -rf /" "'; id #" "\$(id)" "\`id\`"
check "shell metacharacters in the filters are stripped, not executed" \
	"$(jnum "$WORK/out.json" matched)" "0"
check "and the response is still well formed" \
	"$(jnum "$WORK/out.json" accept)" "$N_ACCEPT"

if command -v python3 >/dev/null 2>&1; then
	query 200 0 0 "" "" "" ""
	if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/out.json"; then
		ok "the output parses as JSON"
	else
		bad "the output parses as JSON"
	fi
fi

echo
echo "stale service detection"

# fwlive-status has to tell an option that is configured from an option that is
# actually running, because an upgrade replaces the follower on disk while the
# running one carries on with the old code. It used to look for the follower's
# startup line in logread, which is one line in a ring the deny feed itself
# fills, so it aged out and every later run claimed the service was stale.
# The evidence is a file the running process writes instead.
stale_line() {
	# $1 pid the marker file claims, empty for no marker file at all
	rm -rf "$WORK/srun"
	mkdir -p "$WORK/srun"
	printf 'shed 0\ntrimmed 0\nseq 5\nmerged 3\n' > "$WORK/srun/stats.log"
	echo "$STALE_PID" > "$WORK/srun/pidfile"
	[ -z "$1" ] || printf 'pid %s\nmerge_rules 1\n' "$1" > "$WORK/srun/running"
	FWLIVE_RUN=$WORK/srun FWLIVE_PIDFILE=$WORK/srun/pidfile FWLIVE_MERGE_RULES=1 \
		$RUNSH "$BIN/fwlive-status" 2>/dev/null |
		sed -n 's/^merge rules: *//p'
}

# Something that is genuinely alive, so the status script agrees the service is
# running and the check is reached at all.
sleep 30 &
STALE_PID=$!

case "$(stale_line "$STALE_PID")" in
	yes,*) ok "a follower that wrote the marker is not called stale" ;;
	*) bad "a follower that wrote the marker is not called stale" ;;
esac

case "$(stale_line "")" in
	configured\ on,*) ok "a follower too old to write the marker is called stale" ;;
	*) bad "a follower too old to write the marker is called stale" ;;
esac

case "$(stale_line 999999)" in
	configured\ on,*) ok "a marker left by a killed follower does not answer for the live one" ;;
	*) bad "a marker left by a killed follower does not answer for the live one" ;;
esac

kill "$STALE_PID" 2>/dev/null
wait "$STALE_PID" 2>/dev/null

echo
echo "restart leaves nothing behind"

# An upgrade runs stop then start, and stop only asks procd to stop the old
# follower and returns, so two instances overlap. Everything the follower owns
# is keyed on fixed paths in $RUN, so an overlap used to end with the old
# instance killing the new one's reader out of a pid file the new one had just
# rewritten, while its own reader and parser carried on through a fifo that had
# since been unlinked. That pair then survived every later upgrade, which is
# how a router ends up with two logread, two conntrack and four awk.
#
# The real follower is run here, with both feeds faked, because the bug is in
# how the processes are brought down and nothing smaller than that has it.
FEEDW=$WORK/restart
mkdir -p "$FEEDW/bin" "$FEEDW/run"
# Both fakes ignore SIGPIPE, because the real ones effectively do: `logread -f`
# can sit for hours without writing a byte, so it never notices that the fifo it
# writes into has lost its reader. A fake that quietly died of SIGPIPE instead
# would clean up after leaks that on a router last until the next reboot, and
# the tests below would pass over a follower that leaks.
cat > "$FEEDW/bin/logread" <<'EOF'
#!/bin/sh
trap '' PIPE
while :; do
	echo "kernel: reject wan in: IN=eth0 OUT= SRC=192.0.2.1 DST=198.51.100.1 PROTO=TCP SPT=1 DPT=2" 2>/dev/null
	sleep 1
done
EOF
cat > "$FEEDW/bin/conntrack" <<'EOF'
#!/bin/sh
trap '' PIPE
while :; do
	echo "    [NEW] tcp      6 120 SYN_SENT src=192.0.2.2 dst=198.51.100.2 sport=3 dport=4" 2>/dev/null
	sleep 1
done
EOF
printf '#!/bin/sh\nexit 0\n' > "$FEEDW/bin/logger"
chmod 755 "$FEEDW/bin"/*
# Written rather than discovered, so the follower does not shell out to the
# real fwlive-subnets on the machine running the tests.
printf '4 192.168.1.0 24\n' > "$FEEDW/run/subnets"
cp "$BIN/fwlive-follow" "$FEEDW/follow"
chmod 755 "$FEEDW/follow"

# Every descendant of a follower: its feed and ticker subshells, and their
# readers and parsers.
feed_tree() {
	_t=$1
	for _a in $(pgrep -P "$1" 2>/dev/null); do
		_t="$_t $_a"
		for _b in $(pgrep -P "$_a" 2>/dev/null); do
			_t="$_t $_b"
		done
	done
	echo "$_t"
}

await_follower() {
	# $1 the pid the marker file has to name, so this waits for the instance
	# that is actually up rather than for the file to merely exist
	_n=0
	while [ "$_n" -lt 20 ]; do
		[ "$(awk '$1 == "pid" { print $2 }' "$FEEDW/run/running" 2>/dev/null)" = "$1" ] && return 0
		sleep 1
		_n=$((_n + 1))
	done
	return 1
}

# $1 how the first instance goes: term is an ordinary restart, kill is procd
# losing patience with one that did not stop in time.
restart_survivors() {
	rm -rf "$FEEDW/run"
	mkdir -p "$FEEDW/run"
	printf '4 192.168.1.0 24\n' > "$FEEDW/run/subnets"

	# The readers are named rather than put on PATH: busybox ash resolves its
	# own logread applet before it looks there, so a fake would be ignored.
	#
	# Both instances are detached from this function's stdout. Without that a
	# leaked reader or parser inherits the pipe of the command substitution
	# the caller is reading, and the test hangs instead of reporting the leak
	# it was written to catch.
	FWLIVE_RUN=$FEEDW/run FWLIVE_LOGREAD=$FEEDW/bin/logread \
		FWLIVE_CONNTRACK=$FEEDW/bin/conntrack \
		$RUNSH "$FEEDW/follow" >/dev/null 2>&1 &
	_a=$!
	_why=
	await_follower "$_a" || _why="the first follower never came up"
	sleep 1
	_atree=$(feed_tree "$_a")

	# kill: procd losing patience with a follower that did not stop in time.
	# legacy: what upgrading from 1.0.4 or older looks like, where the init
	# script had already deleted the pid files before the follower was asked
	# to stop, so its reader and parser were orphaned with nothing naming them.
	if [ "$1" = kill ] || [ "$1" = legacy ]; then
		[ "$1" = legacy ] && rm -f "$FEEDW/run"/reader.*.pid \
			"$FEEDW/run"/ticker.*.pid "$FEEDW/run"/parser.*.pid
		kill -KILL "$_a" 2>/dev/null
	fi

	FWLIVE_RUN=$FEEDW/run FWLIVE_LOGREAD=$FEEDW/bin/logread \
		FWLIVE_CONNTRACK=$FEEDW/bin/conntrack \
		$RUNSH "$FEEDW/follow" >/dev/null 2>&1 &
	_b=$!
	[ -n "$_why" ] || await_follower "$_b" || _why="the second follower never came up"
	sleep 2

	_left=
	for _p in $_atree; do
		kill -0 "$_p" 2>/dev/null && _left="$_left$_p "
	done

	# What is left of the first instance is only half the question. A restart
	# that takes the old processes down and fails to bring the new ones up is
	# just as wrong, and under one shell or another this bug did both, so the
	# whole steady state is what gets compared: one reader per feed, and
	# events still arriving.
	#
	# Whether the parsers are alive is read off the spool rather than from the
	# process list, because busybox ash runs awk as an applet inside a forked
	# copy of itself, where it has the shell's command line and no name to be
	# found by.
	_lr=$(pgrep -c -f "$FEEDW/bin/logread" 2>/dev/null || true)
	_ct=$(pgrep -c -f "$FEEDW/bin/conntrack" 2>/dev/null || true)
	_was=$(wc -l < "$FEEDW/run/events.log" 2>/dev/null | tr -d ' ')
	sleep 2
	_now=$(wc -l < "$FEEDW/run/events.log" 2>/dev/null | tr -d ' ')
	if [ "${_now:-0}" -gt "${_was:-0}" ]; then
		_flow=flowing
	else
		_flow=stopped
	fi

	# Unconditionally, and before anything is reported: a run that went wrong
	# is exactly the run that has processes to clear, and leaving them would
	# hand the next case a dirty machine.
	kill -TERM "$_a" "$_b" 2>/dev/null
	sleep 1
	pkill -9 -f "$FEEDW" >/dev/null 2>&1
	# Named, not a bare wait: this runs with other background jobs of the
	# suite still going, and a bare wait would sit on those too.
	wait "$_a" "$_b" 2>/dev/null

	if [ -n "$_why" ]; then
		echo "$_why"
	else
		echo "leftovers:[$_left] logread:${_lr:-0} conntrack:${_ct:-0} events:$_flow"
	fi
}

# One reader per feed, events still arriving through it, and nothing at all
# from the instance that was replaced.
RESTART_OK="leftovers:[] logread:1 conntrack:1 events:flowing"

if command -v pgrep >/dev/null 2>&1 && command -v pkill >/dev/null 2>&1; then
	check "an ordinary restart leaves one live instance and no remains" \
		"$(restart_survivors term)" "$RESTART_OK"
	check "so does one where the old instance never got to shut down" \
		"$(restart_survivors kill)" "$RESTART_OK"
	check "and one upgrading from a release that orphaned its own feeds" \
		"$(restart_survivors legacy)" "$RESTART_OK"

	# Something that only looks like a feed reader: the same command line, run
	# by hand, with no descriptor on the run directory. `conntrack -E -e NEW`
	# is what this repository tells a person to run to check the feed, so the
	# sweep meeting one is not a hypothetical. It lives outside $FEEDW so that
	# the cleanup inside restart_survivors cannot be what spares it.
	cat > "$WORK/looks-like-conntrack" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
	chmod 755 "$WORK/looks-like-conntrack"
	"$WORK/looks-like-conntrack" -E -e NEW >/dev/null 2>&1 &
	BYSTANDER=$!
	sleep 1
	restart_survivors term >/dev/null
	if kill -0 "$BYSTANDER" 2>/dev/null; then
		ok "a command that only looks like a feed reader is left alone"
	else
		bad "a command that only looks like a feed reader is left alone"
	fi
	kill "$BYSTANDER" 2>/dev/null
	wait "$BYSTANDER" 2>/dev/null
else
	skip "restart leaves nothing behind (needs pgrep and pkill)"
	skip "restart leaves nothing behind, hard case (needs pgrep and pkill)"
	skip "restart leaves nothing behind, legacy case (needs pgrep and pkill)"
	skip "a lookalike command is left alone (needs pgrep and pkill)"
fi

echo
if [ "$SKIP" -gt 0 ]; then
	echo "$PASS passed, $FAIL failed, $SKIP skipped"
	echo "a skipped replay is a capture this parser is not actually tested against;"
	echo "see tests/fixtures/README.md"
else
	echo "$PASS passed, $FAIL failed"
fi
[ "$FAIL" = 0 ] || exit 1
exit 0
