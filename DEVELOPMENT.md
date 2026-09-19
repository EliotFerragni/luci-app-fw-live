# Development

Notes for working on luci-app-fw-live. See [README.md](README.md) for
installing and configuring it.

## Repository layout

    package/luci-app-fw-live/   the OpenWrt package
    build-ipk.sh                builds the .ipk without an SDK (24.10 and older)
    build-apk.sh                builds the .apk without an SDK (25.12 and newer)
    tools/pkg-meta.sh           what both builders read out of the package Makefile
    install.sh                  installs straight onto a running router
    tools/preview.py            runs the LuCI view with no router
    tools/capture-fixtures.sh   Phase 0, to be run ON the router
    tests/run-tests.sh          fixture replay and query cases
    README.md                   the user-facing document
    CLAUDE.md                   constraints that aren't visible in the code

Read `CLAUDE.md` before changing anything: it records the busybox, ubus and
LuCI constraints the code is shaped around, including two that bite
immediately (no `^` in awk on some busybox builds, and no single quote
anywhere inside the parser).

## What the hardware already answered

The design rests on facts about the target kernel and its fw4 build that
cannot be checked on a laptop, above all that **a denied packet never produces
a NEW conntrack event**. That has been checked on OpenWrt 24.10.5 on
mediatek/filogic and it holds; `CLAUDE.md` records it along with the log
format the capture pinned down, and what is still open.

`tools/capture-fixtures.sh` is what asked those questions, and it is worth
re-running on a different build or after a major upgrade:

    scp tools/capture-fixtures.sh root@192.168.1.1:/tmp/
    ssh root@192.168.1.1 'sh /tmp/capture-fixtures.sh /tmp/fwlive-fixtures'

`tests/fixtures/README.md` has the full recipe for turning that into a new
replay case, including the part the capture script cannot get for you: the
local prefixes the direction column is derived from.

## How the two feeds are joined

The README says what a user sees; this is the part behind it. `CLAUDE.md` has
the full reasoning and the hardware captures it came from, including the
rejected alternatives such as NFLOG, which fw4 cannot express.

fw4 writes a **verdict** into the prefixes it generates itself (`reject wan
in: `), but a rule logged through `option log '1'` gets only its own **name**.
A name is not a verdict: a rule called `Block-Internet` was captured logging
both packets it let through to a local resolver and packets it refused to the
internet, under one identical prefix. So a verdict is arrived at three ways,
in this order:

1. **From the prefix**, when fw4 put one there.
2. **By pairing two log lines** (`merge_rules`, in the follower). A refused
   packet is usually logged twice, once by the rule it matched and once by the
   chain that refuses it, and the two carry the same IP `ID=`. They become one
   row with the name from the first and the verdict from the second. Several
   rules can log one packet, in which case the Rule column becomes the path it
   took, `A > B`.
3. **Against the conntrack feed** (in `fwlive-query`). A packet that was
   allowed leaves a conntrack entry and a refused one does not, and fw4 accepts
   established traffic before any rule runs, so a matching conntrack event is
   proof the packet was allowed. That row becomes Accepted and keeps its rule
   name, and the conntrack event is not also shown as a row of its own.

Only the positive half of 3 is inferred. The absence of a conntrack event is
never read as a refusal, because the accept feed may be off or the event may
have been trimmed, so what is left over stays `unknown`.

What deliberately does **not** get folded together: a broadcast flooded to four
bridge ports is four log lines sharing an IP `ID=` and a five tuple, differing
only in which port they left by. Those are four forwarding decisions, so the
match key includes the interfaces and they stay four rows.

## Building

    ./build-ipk.sh    OpenWrt 24.10 and older, -> luci-app-fw-live_<version>-<release>_all.ipk
    ./build-apk.sh    OpenWrt 25.12 and newer, -> luci-app-fw-live-<version>-r<release>.apk

**`build-apk.sh` needs docker**, unless you have apk-tools 3 on the machine,
which almost nobody does. It runs one `docker run --rm` against `alpine:edge`,
pulling that image the first time: 8 MB, and the only thing either builder
leaves on the machine. `docker rmi alpine:edge` takes it back. Everything else
happens in the repository and in a temporary directory that goes on the way
out. `build-ipk.sh` needs nothing but `tar`. Why is below.

No OpenWrt SDK needed for either. The package is shell, ucode and JavaScript
only, so `PKGARCH:=all` and nothing is cross compiled. Both read the version,
the metadata, the dependencies, the conffiles and all three maintainer scripts
out of `package/luci-app-fw-live/Makefile` through `tools/pkg-meta.sh`, so
there is one copy of each and the two builders cannot drift apart.

The `.ipk` is an ar archive of tarballs and `tar` is all it takes. The `.apk`
is not: it is a signed ADB container, and the only thing that writes one is
`apk mkpkg` from apk-tools 3. Note that this is **not** the `apk` on the
router, which OpenWrt builds with `-Dminimal=true` and which has no `mkpkg`.
`build-apk.sh` uses apk-tools from the host when it finds one, and otherwise
runs `apk mkpkg` in an `alpine:edge` container, which carries a new enough
apk-tools (3.0.7 against the 3.0.5 OpenWrt 25.12 ships). So either install
apk-tools 3 or have docker; the script stops and says so when it finds neither.

The container runs as root and chowns the staged tree, then hands it back to
the calling user before it exits. Without that last part the temporary
directory stays root-owned and the cleanup on the way out cannot remove it.

apk records the owner of every file, so the staged tree has to be root's.
Running as root or having `fakeroot` covers that on the host, and the container
path is root anyway.

What the `.apk` contains follows `include/package-pack.mk` from the OpenWrt
tree, which is what the SDK would run. Two parts of it are easy to miss:

- the file list and the conffile checksums under `/lib/apk/packages` are part
  of the package payload rather than its metadata, and the list is generated
  before the conffile bookkeeping so that it does not describe itself;
- the maintainer scripts are not shipped as written. apk splits what opkg kept
  in one script, so `postinst` is wrapped into both `post-install` and
  `post-upgrade`, and `prerm` becomes `pre-deinstall`, which apk runs **only**
  on a real removal. Verified against apk-tools 3.0.7: an install runs
  `post-install`, an upgrade runs `post-upgrade` alone, and neither deinstall
  script fires until the package is actually removed. That is why `prerm` can
  ask opkg whether this is an upgrade and be right on both.

## Testing a change on a router

`install.sh` copies the files in place without going through a package
manager at all, which is the fastest edit-and-try loop and works the same on
every release:

    scp -r . root@192.168.1.1:/tmp/luci-app-fw-live-src
    ssh root@192.168.1.1 'sh /tmp/luci-app-fw-live-src/install.sh'

## Testing without a router

    ./tests/run-tests.sh

It puts busybox applets in front of `PATH` when busybox is installed, because
busybox awk is what the router runs and it is stricter than gawk in the ways
that matter. Three groups of cases:

- **fixture replay** feeds captured feed text through the real parser in
  `fwlive-follow --parse` and diffs the event lines against a checked in
  expected file. The parser is where this project will actually break, so this
  is the highest value test in it. There are two cases: `router`, a real
  capture off the target hardware, and `synthetic`, written by hand to cover
  what that one capture window did not contain. A case whose files are
  incomplete is reported as SKIP and counted on its own line, because a
  skipped replay is a capture the parser is not actually tested against.
- **rate limit and trim** push a flood through the same parser and check what
  is shed, what is kept, and that nothing is lost or duplicated.
- **synthetic buffer** generates event lines directly and runs the real
  `fwlive-query` over them, covering every filter, the cursor arithmetic, the
  counts, the output size, and that shell metacharacters in a filter are
  stripped rather than executed.

`--bless` rewrites the expected replay files from whatever the parser
currently does. It records behaviour, it does not verify it, so read the diff
before committing.

The `FWLIVE_` variables are what make this possible: `FWLIVE_RUN` sets the
spool directory, `FWLIVE_PIDFILE` points `fwlive-status` at a pid file it can
write, `FWLIVE_LOGREAD` and `FWLIVE_CONNTRACK` put something else behind the
two feeds, `FWLIVE_BOOT`, `FWLIVE_UPTIME` and `FWLIVE_CLOCK` pin the clock, and
`FWLIVE_MAX_RATE`, `FWLIVE_BUFFER_SIZE`, `FWLIVE_IGNORE_LOCAL` and
`FWLIVE_IGNORE_UNKNOWN` set the defaults used when `/etc/config/fw-live`
cannot be read. uci wins over all of them on a router.

Naming the readers rather than putting them on `PATH` is deliberate: busybox
ash resolves an applet name before it looks at `PATH`, so a fake `logread`
earlier in `PATH` is simply ignored by the shell the router runs.

Pinning the clock matters more than it sounds: a captured feed is replayed in
a few tens of milliseconds, so whether `/proc/uptime` ticks over partway
through decides what the per second rate limiter does with the tail of it.
Setting `FWLIVE_BOOT` is what pins it, and it is also what stops the parser
re-deriving the boot epoch as it goes; leave it unset and set `FWLIVE_CLOCK`
instead to drive that correction from a file a test controls.

Running one feed by hand is often faster than reasoning about it:

    FWLIVE_RUN=/tmp/try mkdir -p /tmp/try
    FWLIVE_RUN=/tmp/try ./package/luci-app-fw-live/files/usr/bin/fwlive-follow \
        --parse log < tests/fixtures/logread-denies.txt
    cat /tmp/try/events.log

## Running the view without a router

    python3 tools/preview.py --live

That puts the LuCI page on `http://127.0.0.1:8099` and is the fastest way to
work on `main.js`. It writes synthetic events in the format the follower
spools, and answers the page's rpc calls by running the real `fwlive-query`
against them, so the filters, the cursors and the incremental tail behave as
they do on a router. Nothing about the page is reimplemented: the view file
runs as-is behind stubs shaped like LuCI's `E`, `rpc`, `uci`, `view`, `poll`
and `network`.

`--live` keeps appending new events while it serves, which is what exercises
the tail and the pause button; without it the buffer is a fixed window.
`--minutes N` decides how much history it starts with, `--port N` moves it,
`--dark` renders in a dark theme, and `--time-format` / `--date-format` say
what the page is told those settings are. The page reports what it drew, and
anything it throws, to the terminal, which saves opening devtools.

The README images come from the same script:

    python3 tools/preview.py --screenshots

which writes `docs/*.png` through headless Firefox instead of serving. An
image that stops matching the code means the code moved.

Needs `python3-pil` and `firefox` for `--screenshots`; it uses `busybox` for
awk and date when installed. Every window ends at the current time, so each
run shifts the clock labels: regenerate the images when the page changed, not
out of habit.

`python3 tools/preview.py` also serves the settings page on `/settings`, with
the firewall logging panel wired to the real `fwlive-logging` against a fake
`uci` and a fake firewall config in the work directory. Ticking a box and
pressing Apply really does rewrite that file, so the panel can be worked on
without a router. The CBI part of that page is a stub and only approximates
what LuCI draws; the panel below it is plain DOM and is the real thing.

A view that throws leaves a blank page and says nothing, which is the worst
way to develop one, so both preview pages report exceptions to the terminal
and the screenshot mode prints them into the image.

## What cannot be tested here

The ucode backend needs rpcd, and LuCI's own CBI rendering needs a browser
with LuCI in it. Keep `luci.fw_live.uc` small and boring for that reason:
`popen` a script, sanitise every argument, `json()` the result in a `try`,
return an `{ error }` object on failure.

## Continuous integration

`.github/workflows/build.yml` has two jobs:

- **check** runs on every push and pull request: `sh -n` on the shell scripts,
  `node --check` on the LuCI views, a JSON parse of the ACL and menu files,
  and `tests/run-tests.sh` against a busybox it installs.
- **package** builds the `.ipk`. It does *not* run on ordinary pushes. It runs
  only when the workflow is started by hand (Actions → build → Run workflow),
  where the `.ipk` is a run artifact kept for 3 days, and when a GitHub release
  is published, where the `.ipk` is uploaded to that release.

Pushing a tag on its own builds nothing, and a release left as a draft
publishes nothing: the upload happens at the moment the release is published.

## Release procedure

1. Bump `PKG_VERSION` in `package/luci-app-fw-live/Makefile` and reset
   `PKG_RELEASE` to `1`. Bump `PKG_RELEASE` alone when only the packaging
   changed and no installed file did.
2. Update the README: the version in the title and the filename in the install
   commands.
3. Sanity check both builds with `./build-ipk.sh` and `./build-apk.sh`.
4. Commit and push to `main`.
5. On GitHub, Releases → Draft a new release. Set the tag to `v<PKG_VERSION>`
   (`v1.2.3` for `PKG_VERSION:=1.2.3`) targeting that commit, write the notes
   describing what changed, and publish. The release notes are the changelog;
   the repository does not keep one.
6. Publishing triggers the workflow, which builds the `.ipk` and the `.apk`
   and attaches both to the release. Check the run finished and both assets
   are on the release page.
7. The same run asks [the signed feed](https://github.com/EliotFerragni/openwrt-feed)
   to rebuild, so routers subscribed to it see the new version. That step needs
   the `FEED_DISPATCH_TOKEN` secret; without it the run only prints a warning
   and the feed keeps serving the previous release until its `publish` workflow
   is run by hand.

The tag is created by GitHub when the release is published, so there is no
need to tag by hand beforehand.

Mark a release as a **pre-release** and the feed will skip it: `build-feed.sh`
reads `releases/latest`, which ignores drafts and pre-releases.

## Acceptance, on the router

With zone logging enabled on wan:

- From outside, hit a port the wan zone rejects. The row appears within one
  poll interval, marked rejected, with the right source address and
  destination port, and the fw4 prefix in the Rule column.
- From a LAN host, open a connection to the internet. It appears marked
  accepted, with the host's name resolved, and an empty Rule column.
- Set `option log '1'` on one uci firewall rule, reload the firewall, trigger
  it. That event now carries the rule's name.
- `/etc/init.d/fw-live status` reports the service running, conntrack events
  available, and which zones have logging on.
- Remove the zone's log option: the status line says logging is off and prints
  the uci commands to turn it back on, and the accept feed keeps working.
- Leave the page open for an hour on a busy network. `buffered` stays at
  `buffer_size`, `/tmp/fw-live` stays bounded, and the page does not slow down.
- `fw4 print` before and after installing the package is identical.

## Built with Claude Code

This package was written by [Claude Code](https://claude.com/claude-code)
across a series of sessions: the capture service, the parser, the ucode
backend, the LuCI views, the build scripts, the tests and this documentation.
What to build, which trade-offs to take and what counted as broken came from
the human side, as did every run on the target hardware. Every commit written by Claude
carries a `Co-Authored-By: Claude` trailer, so the history says
which is which.

`CLAUDE.md` is what the agent is handed at the start of a session: the
constraints that are not visible from the code, the measurements the design
rests on, and the mistakes already made once. It is worth reading before
changing anything here, whoever or whatever is doing the changing.
