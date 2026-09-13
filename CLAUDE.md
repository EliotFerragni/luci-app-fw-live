# CLAUDE.md

Notes for working on this repository. Most of it is about constraints that
aren't visible from the code itself.

## What this is

An OpenWrt LuCI app that shows what the firewall is accepting and refusing,
right now. The reference point is Fortinet's FortiView forward traffic log: a
live, filterable event stream where a blocked connection appears the moment
someone tries it.

It measures nothing and adds nothing to the ruleset. It reads two feeds the
kernel already produces and buffers the last few minutes of them in RAM. That
is why it has no effect on software or hardware flow offloading, which matters
on the target hardware (Banana Pi R4). Do not replace either feed with
`nft monitor trace`, per packet inspection or extra firewall rules.

It answers "what is the firewall doing right now", not "how much did each
device transfer, over time".

**Byte counts and application identification are out of scope.** Volume is a
different question entirely, and there is no DPI on this platform worth
having.

## Layout

    package/luci-app-fw-live/Makefile     OpenWrt package definition
    package/luci-app-fw-live/files/       everything that gets installed
    build-ipk.sh                          builds the .ipk without an SDK
    install.sh                            installs onto a running router
    tools/preview.py                      runs the LuCI view with no router
    tools/capture-fixtures.sh             Phase 0: run this ON the router
    tests/run-tests.sh                    fixture replay and query cases
    README.md                             user-facing: install, setup, options
    DEVELOPMENT.md                        build, CI and release procedure

Installed files:

    /usr/bin/fwlive-follow      procd service: both feeds, one parser
    /usr/bin/fwlive-query       filters the buffer, prints JSON
    /usr/bin/fwlive-status      diagnostics, the single entry point
    /usr/bin/fwlive-subnets     refreshes the local-prefix cache
    /usr/share/rpcd/ucode/luci.fw_live.uc     ubus backend
    /www/luci-static/resources/view/fw-live/  the LuCI views

## The two feeds, and why they are asymmetric

| half of the question | source | rule name? |
| --- | --- | --- |
| what was **refused** | fw4's kernel log, via `logread -f -e 'IN='` | yes, from the log prefix |
| what was **accepted** | `conntrack -E -e NEW` | no |

This asymmetry is the shape of netfilter, not laziness. A drop is an event
that only exists if something logs it. An accept leaves a conntrack entry
behind, and that entry is confirmed only once the packet has cleared the
ruleset, which makes NEW a free and complete accept feed costing no firewall
rules and no log volume.

Zone logging is not the complete deny feed it looks like. It covers what the
**zone policy** refuses. A packet refused by a **rule** whose target is REJECT
or DROP is decided by that rule, so it never reaches the zone's logging rule,
and having been refused it produces no conntrack event either. Nothing records
it at all. There is no switch that fixes this for good, so `fwlive-status`
reports every deny rule that does not log, with the commands to fix it, and
both views surface that. A rule added later then announces itself rather than
quietly going unseen.

The consequence, which the README states plainly: **accepted connections
normally have an empty Rule column.** Setting `option log '1'` on one uci
firewall rule gets a name onto that specific event, through the log feed.

Rejected alternatives, for the record: `nft monitor trace` gives exact per
packet rule attribution but is far too heavy to leave running; logging every
accept gives names everywhere but floods the log on a normal LAN; per rule
nftables counters give hit counts but not connections.

**NFLOG** deserves its own note, because it is the obvious objection: nftables
`log group N` sends the packet to a netlink group instead of to printk, which
is the exact analogue of the conntrack event stream and would keep firewall
events out of the system log entirely. It is rejected because **fw4 cannot
express it**. `option log '1'` renders a plain `log prefix ...` with no group
and there is no uci option for one, so NFLOG means hand written nft rules in
`/etc/nftables.d/` running in parallel with fw4's own, which the user has to
keep correct as their firewall changes. That is a far bigger request than
`uci set ... log='1'`, in the one file where a mistake costs remote access,
and it breaks the rule that this package never edits the firewall. Reading the
group also needs ulogd2 or libpcap's nflog device. Revisit if fw4 gains a log
group option; the follower is already shaped for a third feed, since each one
is a separate process with its own spool.

## Verified on the target hardware

From a 60 second capture on OpenWrt 24.10.5, mediatek/filogic, conntrack
v1.4.8, `nf_conntrack_events=2`. The capture and the report it came with are
in `tests/fixtures/` as the `router` case and `phase0.txt`.

- **The load bearing assumption holds: a denied packet does not produce a NEW
  conntrack event.** Both feeds were captured over the same window and give
  214 denied 5-tuples against 433 accepted, with zero overlap, and still zero
  when source port is ignored. If this ever stops being true the accept feed
  is wrong and the design has to fall back to log based accepts, so re-run the
  check rather than assuming it carries over to another build.
- **fw4 prefixes end with `": "`** and read `reject wan in: `,
  `reject wan out: `, `reject <zone> forward: `, `drop wan invalid ct state: `.
  Both verdict words appear, which is what the prefix match relies on.
- **The log line uses the combined `MAC=` field**, not
  `MACSRC`/`MACDST`/`MACPROTO`, carries `PHYSIN=` on bridged paths and a
  trailing `MARK=`. None of that matters because keys are located by name, but
  it is why fixtures must be captured rather than remembered. Note `PHYSIN=`
  contains the substring `IN=`; anything matching on text rather than on a
  whole key will get this wrong.
- **A zone can be a named uci section.** This firewall has
  `firewall.iot.log='1'`, which walking `firewall.@zone[N]` alone never
  sees. `fwlive-status` keys on the uci section identifier for that reason.
- **conntrack lines carry a trailing `mark=`** and repeat `src`/`dst` for the
  reply tuple, which is why the first of each key wins.
- **A log prefix names whatever wrote the line, which is not necessarily the
  rule that decided the packet, and one packet can produce two lines under two
  different prefixes.** fw4 renders a rule with `option src '*'`,
  `option dest 'wan'` and `option target 'REJECT'` as a single rule in the
  forward chain:

      ether saddr { 00:00:5e:00:53:01, 00:00:5e:00:53:02 } counter \
          log prefix "Block-Internet: " jump reject_to_wan

  The destination zone became the **jump target**, not a match. So the rule
  logs every packet from those MACs whatever its destination, then jumps into
  the shared `reject_to_wan` chain, whose own rule matches the wan output
  interfaces, logs `reject wan out: ` and rejects. A packet not bound for wan
  falls through that chain, returns, and carries on to the ordinary zone
  forwarding.

  Three consequences, all of which the view has to live with: a rule logs
  traffic it has no intention of refusing (21 of 38 lines in one snapshot were
  accepted traffic); its refusals are logged under the shared chain's prefix
  rather than its own name, so `reject wan out` does not tell you whether the
  zone policy or a named rule refused the packet; and the same packet appears
  twice, once as `unknown` with the rule name and once as `reject` without it.
  The first two are the cost of per rule logging and cannot be avoided. The
  third is what `merge_rules` fixes: the parser holds an event whose prefix
  carries no verdict, and if the next line is the same packet, by family,
  protocol, addresses, ports and IP `ID=`, the two become one row with the
  verdict from the second and the rule name from the first.

  A packet can match several logging rules, each writing a name and none of
  them a verdict, so consecutive verdictless lines for the same packet chain
  into one row whose rule column is the path taken, `A > B`, capped at 96
  characters because nothing bounds how many rules can log.

  **The match key includes the interfaces, and has to.** A broadcast flooded
  to four bridge ports is four log lines sharing an IP ID and a five tuple,
  differing only in `PHYSOUT`. They are four forwarding decisions, not one
  packet logged four times, and a key without the interfaces would quietly
  fold three of them away.

  One slot, not a ring, because the two lines are the same packet still moving
  through the ruleset and arrive back to back. Anything that does not pair
  immediately is released unchanged, so a missed pairing costs only the merge.
  The held event is released by the next line to arrive, which on a silent log
  could be a long time, so the follower feeds a `__fwlive_tick__` line into the
  log fifo once a second purely to wake the parser. That ticker keeps the fifo
  open for its whole life, because a moment with no writer at all reads as end
  of file, and it exits when the reader does, so a dead feed still ends as end
  of file and restarts. Cross feed pairing is a different matter and is
  done differently: in `fwlive-query`, not in the follower, and only in one
  direction. A packet that was allowed leaves a conntrack entry and a refused
  one does not, and fw4 accepts established traffic before any rule runs, so
  everything reaching a rule is a new connection and a matching conntrack
  event is positive proof the packet was allowed. An `unknown` event with such
  a match is reported as `accept`, keeping its rule name.

  The absence of a match proves nothing and is never read as a refusal: the
  accept feed may be off, or the event may have been trimmed. The accepted
  feed is read first so its tuples are in hand, only events from the last 30
  seconds are indexed so the array stays small, and a match must be within 5
  seconds or a reused ephemeral port would resolve an old row against a new
  flow. It works at all only because the follower already holds a verdictless
  event about a second, which is long enough for its conntrack event to land
  first.
- **A broadcast is logged once per bridge port it is flooded to.** One packet,
  `ID=4571`, produced four log lines differing only in `PHYSOUT=`. Anything
  that reads `OUT=` alone sees four identical events. It is also a log
  amplifier on a bridge with many ports, which is part of what `max_rate` and
  `ignore_local` are for.

- **`conntrack -E` flushes per event.** Confirmed with `conntrack -E -e NEW |
  cat`: rows appear as they happen rather than in bursts, so no unbuffering
  wrapper is needed. This matters because the page is a live tail, and an
  event sitting in a stdio buffer until the next 4 KB is as good as lost.

- **A per-rule log prefix carries the rule's name and nothing else, and the
  same name appears on packets that were accepted and packets that were
  refused.** Captured from a rule called `Block-Internet`: two UDP
  packets to a local resolver that were accepted and one TCP packet to the
  internet that was refused, all three logged with the identical prefix and
  differing in nothing that distinguishes the outcome. The `namedrule` fixture
  case is those three lines.

  So the verdict is not recoverable from the log for any rule logged through
  `option log`, and `unknown` is the honest answer rather than a fallback.
  Note also that a uci rule name is not unique and `option log_prefix` lets it
  be anything at all, so even a prefix that does contain the word "accept"
  is a label rather than a fact. Zone and default rules are the exception:
  fw4 writes the verdict into those prefixes itself.

Everything Phase 0 asked has now been answered on hardware.

## The event record

One tab separated line per event, fixed column count so busybox awk stays
trivial. Empty fields are written as `-`, never as an empty string, so a
trailing empty field cannot be lost.

    ts  seq  src  verdict  fam  proto  saddr  sport  daddr  dport  iif  oif  dir  rule  extra

- `ts` is stamped by the follower at read time. Do not trust the kernel's
  `[12345.67]` uptime stamp and do not depend on `conntrack -o timestamp`.
- `seq` is monotonic **per source**, so ordering and the incremental cursor
  are exact even within one second.
- `src` is `log` or `ct`, and doubles as the parser's mode.
- `verdict` is `accept`, `drop`, `reject` or `unknown`. Only the log feed can
  produce `unknown`, and it means the prefix carried no verdict word, which is
  every rule logged through `option log`: fw4 puts the rule's name there and
  nothing else. Do not be tempted to default that to `drop`. Per rule logging
  exists mostly to name *accepted* traffic, so the guess would be wrong in the
  common case and would paint a red Dropped chip on a connection that was
  allowed.
- `iif`/`oif` are `IN=`/`OUT=` for log events and `-` for conntrack ones. On a
  bridge they are written `bridge/port`, from `PHYSIN=`/`PHYSOUT=`, because
  without the port a broadcast flooded to four bridge ports produces four rows
  identical in all fifteen columns.

Keys in both feeds are located **by name**, never by position, so a new or
reordered field in either feed changes nothing.

## Hard constraints

**busybox.** Scripts run under busybox `ash` and busybox `awk`, not bash and
not gawk. No `[[`, no `local`, no `gensub`, no `asort`, no time functions.
Timestamps are formatted in shell: `date -D %s -d "$epoch"` is the busybox
spelling with `date -d "@$epoch"` as the GNU fallback. Leading zeros are
stripped with `${_h#0}` before arithmetic, or the shell reads `09` as invalid
octal.

**No `^` in awk.** Some busybox builds are compiled without math support and
answer `2 ^ 30` with "Math support is not compiled in". `pow2()` in
`fwlive-follow` is a loop for that reason. There are no bitwise functions
either, which is why the IPv4 subnet match is a division rather than a mask.

**No single quotes inside the parser.** The awk program in `fwlive-follow`
lives in a single quoted shell variable, so its `logger` and `mv` calls use
escaped double quotes. Adding a `'` anywhere in it breaks the script silently
at the shell level.

**The spool is closed between events.** Every event is appended, flushed and
the file closed. That is two cheap syscalls at these rates, and it is what
makes the trim safe: the writer never holds a stale descriptor, so rewriting
the spool and renaming it in cannot truncate under a reader. Do not "optimise"
this into an in place truncate or a batched write; this is a live tail.

**One writer per file.** Each feed has its own spool, which is the whole
reason there is no locking anywhere.

**No sorting in the query.** Each spool is appended in time order and trimmed
from the front, so the newest N matching lines are the last N to arrive. The
query keeps a ring per source and merges the two. Busybox awk has no `asort`
and an insertion sort over a full buffer would be far too slow.

**ubus message size.** Everything the backend returns crosses ubus. The page
sends the two cursors it holds, so a 2 second poll carries a handful of rows
rather than the whole page again. The limit is capped at 1000 events.

**LuCI cannot make SVG with `E()`.** Nothing here draws a chart, but if one is
ever added: `E()` uses `document.createElement`, which produces a dead element
for namespaced SVG tags. Build SVG as a string and assign it through
`innerHTML`.

**tmpfs only.** Everything lives in `/tmp/fw-live`, which is RAM. There is no
`data_dir` and no flush machinery: this is a live view and nothing survives a
reboot by design. On OpenWrt `/var` is a symlink to `/tmp`, so there is no
persistent path here to get wrong.

**This package writes exactly one firewall option, and it is `log`.**
`fwlive-logging` is the only place that touches `/etc/config/firewall`, and
`log` is the only option it may ever set. That option decides whether a line
is written, never whether a packet passes, so nothing this package does can
cost anyone access to the router, which is the risk the original rule existed
to avoid. Every other firewall setting is still detect and instruct, never
edit. Do not widen `fwlive-logging` to any other option, however convenient it
looks: the moment it can change a verdict, this package can lock someone out
of their router.

Two consequences worth keeping: `uci commit` applies a whole package, so
anything the user had staged in `firewall` is committed alongside our change
and the result says so; and the ubus method takes only `<section>=0|1` pairs,
checked against a regex in ucode and again against the running config in the
shell, so nothing else can reach a command line.

## Conventions

- Bump `PKG_VERSION` in the package Makefile for any user-visible change, and
  update the version in the README title and install commands to match. There
  is no changelog: what changed goes in the GitHub release notes.
  `DEVELOPMENT.md` has the full release procedure.
- Documentation is split by audience: anything a user of the package needs
  goes in `README.md`, anything only a contributor needs goes in
  `DEVELOPMENT.md`.
- `fwlive-status` is the single diagnostic entry point. It is surfaced by
  `/etc/init.d/fw-live status`, by the settings tab and by the status line on
  the live page. New failure modes should show up there.
- New config options need updating in four places: `files/etc/config/fw-live`,
  the reader in the shell scripts, the settings form, and the README table.
- The `FWLIVE_*` environment variables set the defaults used when
  `/etc/config/fw-live` cannot be read. uci wins over them on a router, so
  they only bite off-router, which is what makes the parser testable.
- Build with `./build-ipk.sh`. It needs no OpenWrt SDK. The package is
  `PKGARCH:=all` because it contains no compiled code.

## Testing without a router

    ./tests/run-tests.sh

runs under busybox when it is installed, because busybox awk is stricter than
gawk in the ways that matter. It covers:

- **fixture replay**: the captured feed text through the real parser, diffed
  against a checked in expected file. `tests/fixtures/README.md` explains
  where those captures come from and how to replace them.
- **rate limit and trim**: a flood through the real parser, checking what is
  shed, what is kept and that nothing is lost or duplicated.
- **synthetic buffer**: generated event lines through the real `fwlive-query`,
  covering every filter, the cursor arithmetic, the counts, the output size
  and that shell metacharacters in a filter are stripped rather than run.

CI additionally runs `sh -n` on every shell script, `node --check` on the
views and a JSON parse of the ACL and menu files.

The whole view also runs outside a router:

    python3 tools/preview.py --live

serves the real `main.js` behind LuCI shaped stubs, with its rpc calls
answered by the real `fwlive-query` over synthetic events, so the filters and
the cursors genuinely work. `--screenshots` writes the README images.

The two things that cannot be tested here are the ucode backend, which needs
rpcd, and the LuCI forms, which need a browser. Keep the ucode file small and
boring for that reason.

## Things that have already gone wrong

Worth not repeating:

- `2 ^ (32 - len)` in awk, which busybox answers with "Math support is not
  compiled in" on builds without libm.
- Parsing `SPT=` and `DPT=` out of the header an ICMP error quotes, which put
  ports on an ICMP event that has none. Only the first token of that quoted
  header carries the `[`, so the parser stops at the bracket.
- A test that failed about one run in twenty, because the follower stamps
  events as boot epoch plus `/proc/uptime` and a captured flood is read in
  ~50 ms: whether uptime ticked over partway through decided whether the rate
  limiter handed the tail of the flood a fresh budget. Nothing wrong with the
  behaviour, only with testing it against a moving clock. The uptime source is
  a variable now (`FWLIVE_UPTIME`) so a replay can pin it. Note the tick is on
  the **uptime** boundary, not the wall clock one: an attempt to reproduce it
  by aligning to `date +%s` found nothing and nearly buried the bug.
- **A `trap` inside the feed loop, which deadlocked shutdown.** That loop
  spends its life blocked on the parser as a foreground child, and a shell
  with a handler installed for a signal defers it until that child returns.
  The parser only returns at end of file, which only happens once the reader
  is gone, which is what the handler was going to do. The feed hung instead of
  stopping, and everything below it leaked. With **no** handler, SIGTERM ends
  the feed outright and the parent then kills the reader, which is why the
  reader pid files exist: they are load bearing, not bookkeeping. The comment
  in `run_feed` says so; do not tidy it into a trap.
- **procd restarts an instance only when its definition changed**, which is
  why `procd_set_param file /etc/config/fw-live` is there: without it a
  settings change re-registered an identical instance, procd saw nothing to
  do, and the running follower carried on with the old configuration.
- A package postinst that ran `/etc/init.d/fw-live start` rather than
  `restart`. procd compares the instance definition it is handed against the
  running one, and ours does not change between versions, so it saw no
  difference and left the old process running against the newly installed
  files. `fwlive-query` is re-read on every call and so upgraded instantly,
  while `fwlive-follow` kept running the previous release: the page showed new
  features driving a buffer filled by old code. `fwlive-status` now detects
  the case.
- An apostrophe in a **comment** inside the single quoted parser, which ends
  the shell string and kills the script at a line number pointing nowhere near
  it. `tests/run-tests.sh` now checks for this, and the check verifies it
  actually found the parser block rather than passing because it looked at
  nothing.
- The prefix cache arriving space separated instead of tab separated, which
  parsed as zero prefixes and reported every direction as unknown, with
  `fwlive-status` still cheerfully saying "8 known" because it counted lines
  rather than usable prefixes. The parser now splits on any whitespace and the
  status counts what the parser would actually accept.
- A files-only package Makefile without an empty `Build/Compile`, which makes
  the default rule run `make` in an empty build directory and fail.
- Forgetting `/tmp/luci-modulecache` when clearing LuCI caches, so a newly
  installed page stays invisible until something else invalidates it.
