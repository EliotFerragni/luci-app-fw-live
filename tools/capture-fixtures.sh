#!/bin/sh
# Phase 0: run this ON THE ROUTER, before trusting anything in this package.
#
# The whole design rests on facts about this kernel and this fw4 build that
# cannot be checked on a laptop. This prints the answers and captures real
# feed output into a directory you copy back into tests/fixtures/.
#
#   scp tools/capture-fixtures.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/capture-fixtures.sh /tmp/fwlive-fixtures'
#
# then copy the result back as one named case, file by file. It prints the
# exact commands when it finishes.
#
# While it runs, generate traffic: browse from a LAN host, and from outside
# hit a port the wan zone refuses.

OUT=${1:-/tmp/fwlive-fixtures}
SECONDS_TO_WATCH=${2:-60}

mkdir -p "$OUT" || exit 1

say() { echo; echo "=== $* ==="; }

{
	say "1. is the conntrack event stream usable at all"
	command -v conntrack >/dev/null 2>&1 && echo "conntrack: $(command -v conntrack)" ||
		echo "conntrack: MISSING, run $(command -v apk >/dev/null 2>&1 && echo 'apk add' || echo 'opkg install') conntrack"
	echo "nf_conntrack_events: $(cat /proc/sys/net/netfilter/nf_conntrack_events 2>/dev/null || echo unreadable)"

	say "2a. does conntrack -E flush per event when its output is not a terminal"
	echo "The whole page is a live tail, so an event that sits in a stdio buffer"
	echo "until the next 4 KB is as good as lost. Check by hand:"
	echo "    conntrack -E -e NEW | cat"
	echo "and confirm rows appear as they happen rather than in bursts. If they"
	echo "burst, this conntrack build is block buffering and the accept feed"
	echo "needs an unbuffering wrapper."

	say "2. the load bearing assumption: a denied packet must NOT produce a NEW event"
	echo "A conntrack entry is only confirmed once the packet has survived the"
	echo "ruleset, so a dropped or rejected packet should never appear as NEW."
	echo "Check this by hand: from outside, hit a port the wan zone refuses"
	echo "while watching conntrack -E -e NEW. If denied packets DO show up,"
	echo "the accept feed is wrong and the design needs log based accepts."

	say "3. what fw4 logs today, and with what prefix text"
	fw4 print 2>/dev/null | grep -n 'log ' | head -40
	echo "--- uci"
	uci show firewall 2>/dev/null | grep -i log

	say "4. zones and their logging state"
	i=0
	while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
		echo "@zone[$i] name=$(uci -q get "firewall.@zone[$i].name") log=$(uci -q get "firewall.@zone[$i].log")"
		i=$((i + 1))
	done

	say "5. per rule logging, which decides whether the Rule column is ever populated"
	i=0
	while uci -q get "firewall.@rule[$i]" >/dev/null 2>&1; do
		_l=$(uci -q get "firewall.@rule[$i].log")
		[ "$_l" = "1" ] && echo "@rule[$i] name=$(uci -q get "firewall.@rule[$i].name") log=1"
		i=$((i + 1))
	done
	echo "(set option log '1' on one rule, reload the firewall, trigger it, and"
	echo " check whether the prefix in the captured log below carries its name)"

	say "versions"
	cat /etc/openwrt_release 2>/dev/null
	fw4 -v 2>/dev/null || true
	conntrack --version 2>/dev/null || true
} > "$OUT/phase0.txt" 2>&1

cat "$OUT/phase0.txt"

echo
echo "Capturing both feeds for ${SECONDS_TO_WATCH}s. Generate traffic now."

logread -f -e 'IN=' > "$OUT/logread-denies.txt" 2>/dev/null &
LPID=$!
conntrack -E -e NEW > "$OUT/conntrack-new.txt" 2>/dev/null &
CPID=$!

sleep "$SECONDS_TO_WATCH"
kill "$LPID" "$CPID" 2>/dev/null

echo
echo "captured $(wc -l < "$OUT/logread-denies.txt") denied lines, $(wc -l < "$OUT/conntrack-new.txt") conntrack events"
echo "in $OUT"
echo
echo "If logread-denies.txt is empty, no zone has logging on yet:"
echo "  uci set firewall.@zone[N].log='1'; uci commit firewall; /etc/init.d/firewall reload"
echo
echo "To turn this into a replay case called <case>, from the repository root,"
echo "one file at a time rather than copying the directory:"
echo
echo "  scp root@ROUTER:$OUT/logread-denies.txt  tests/fixtures/<case>-denies.txt"
echo "  scp root@ROUTER:$OUT/conntrack-new.txt   tests/fixtures/<case>-conntrack.txt"
echo "  scp root@ROUTER:$OUT/phase0.txt          tests/fixtures/<case>-phase0.txt"
echo "  ssh root@ROUTER 'cat /tmp/fw-live/subnets' > tests/fixtures/<case>-subnets"
echo
echo "The subnets file is not optional: the direction column is a function of"
echo "the local prefixes as well as the addresses, so without the ones that"
echo "were in force here the expected output would be a fiction. If the"
echo "package is not installed yet, run fwlive-subnets to write it."
echo
echo "Then add <case> to CASES in tests/run-tests.sh and:"
echo "  ./tests/run-tests.sh --bless     # read the output before committing it"
