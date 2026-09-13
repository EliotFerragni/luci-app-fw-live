# Fixtures

`tests/run-tests.sh` feeds these through the real parser in `fwlive-follow`
and diffs the result against the expected files. The parser is where this
project will actually break, so this is the highest value test in it.

A case is a set of files sharing one name:

| file | what it is |
| --- | --- |
| `<case>-denies.txt` | `logread -f -e 'IN='` output, the deny feed |
| `<case>-conntrack.txt` | `conntrack -E -e NEW` output, the accept feed |
| `<case>-subnets` | what `fwlive-subnets` wrote at the time, because the direction column is a function of both the addresses and the prefixes |
| `expected-<case>-log.tsv` | the event lines the deny feed must parse to |
| `expected-<case>-ct.tsv` | the event lines the accept feed must parse to |

The first column of the expected files is `T` rather than an epoch. The
timestamp is stamped by the follower at read time by design, so it is the one
column that cannot be reproduced; the test blanks it on both sides.

A case whose files are incomplete is reported as SKIP and counted separately
in the tally, never passed over in silence: a skipped replay is a capture the
parser is not actually tested against.

## The cases

**`router`** is a real 60 second capture from the target hardware, OpenWrt
24.10.5 on mediatek/filogic, conntrack v1.4.8. 224 denied packets and 444
accepted connections, over five local prefixes, which is what gives the
direction column a real mix to be right about rather than one subnet. This is what pins the parser to the log format this fw4
really emits: the combined `MAC=` field rather than `MACSRC`/`MACDST`, a
`PHYSIN=` on bridged paths, a trailing `MARK=`, and prefixes ending in `": "`.

**`synthetic`** is written by hand. It exists because one capture window is
not a specification: the router capture contains no IPv6 at all, no ICMP in
the log, no ICMP error quoting the offending header, no bare protocol number
and no per-rule prefix carrying a rule's own name. Every line in it is in the
format the router capture confirmed, and it covers the cases that one happened
to miss. Do not delete it when a richer real capture arrives; add a case.

**`namedrule`** is twenty real lines from a router with `option log` set on
one rule, kept as its own case because of the three things it proves, each of
which has a test of its own:

- the same rule name appears on packets with different outcomes, which is the
  evidence behind the `unknown` verdict existing at all;
- that rule does not decide those packets. Every one of its wan bound packets
  is followed by a `reject wan out` line with the identical `ID=`, so a named
  rule can log a packet that something further down then refuses;
- one broadcast is logged once per bridge port it is flooded to, four times
  here, differing only in `PHYSOUT=`.

Its conntrack file is deliberately empty; only the log feed is the point.

**`chained`** is from the same router after two more logging rules were added,
so that one packet matches several of them. It covers what `namedrule` cannot:
a packet logged by two rules in a row, which has to come out as one row naming
both; an input direction rule, where `OUT=` is empty; and a multicast flooded
to four bridge ports, which shares an IP ID and a five tuple across all four
copies and must **not** be folded into one row. That last one is the trap the
merge key exists to avoid.

`phase0.txt` is the capture script's report from the first run, kept because
it records what that firewall was configured to log at the time.

## Capturing another case

    scp tools/capture-fixtures.sh root@192.168.1.1:/tmp/
    ssh root@192.168.1.1 'sh /tmp/capture-fixtures.sh /tmp/fwlive-fixtures'
    scp root@192.168.1.1:/tmp/fwlive-fixtures/logread-denies.txt  tests/fixtures/<case>-denies.txt
    scp root@192.168.1.1:/tmp/fwlive-fixtures/conntrack-new.txt   tests/fixtures/<case>-conntrack.txt
    ssh root@192.168.1.1 'cat /tmp/fw-live/subnets'             > tests/fixtures/<case>-subnets
    ./tests/run-tests.sh --bless      # only after reading the new output

Add the name to `CASES` in `tests/run-tests.sh`.

`--bless` rewrites the expected files from whatever the parser currently does,
so read its output before committing it: it records behaviour, it does not
verify it.

The subnets file is tab separated, and it has to come from the same router
rather than be invented, or the direction column in the expected output is a
fiction. Pipe it, do not retype it: pasting through an editor turns the tabs
into spaces. The parser tolerates that now, but the fixture should still be
what the router wrote. If the package is not
installed there yet, `sh tools/../package/luci-app-fw-live/files/usr/bin/fwlive-subnets`
writes it, or take the prefixes straight from
`ubus call network.interface dump`.
