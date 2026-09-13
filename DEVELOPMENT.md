# Development

Notes for working on luci-app-fw-live. See [README.md](README.md) for
installing and configuring it.

## Repository layout

    package/luci-app-fw-live/   the OpenWrt package
    build-ipk.sh                builds the .ipk without an SDK
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

## Building

    ./build-ipk.sh

No OpenWrt SDK needed. The package is shell, ucode and JavaScript only, so
`PKGARCH:=all` and nothing is cross compiled. The version comes from
`PKG_VERSION` and `PKG_RELEASE` in `package/luci-app-fw-live/Makefile`, and the
result lands in the repository root as
`luci-app-fw-live_<version>-<release>_all.ipk`.

## Testing a change on a router

`install.sh` copies the files in place without going through opkg, which is
the fastest edit-and-try loop:

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
spool directory, `FWLIVE_BOOT` and `FWLIVE_UPTIME` pin the clock, and
`FWLIVE_MAX_RATE`, `FWLIVE_BUFFER_SIZE`, `FWLIVE_IGNORE_LOCAL` and
`FWLIVE_IGNORE_UNKNOWN` set the defaults used when `/etc/config/fw-live`
cannot be read. uci wins over all of them on a router.

Pinning the clock matters more than it sounds: a captured feed is replayed in
a few tens of milliseconds, so whether `/proc/uptime` ticks over partway
through decides what the per second rate limiter does with the tail of it.

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
3. Sanity check the build with `./build-ipk.sh`.
4. Commit and push to `main`.
5. On GitHub, Releases → Draft a new release. Set the tag to `v<PKG_VERSION>`
   (`v1.2.3` for `PKG_VERSION:=1.2.3`) targeting that commit, write the notes
   describing what changed, and publish. The release notes are the changelog;
   the repository does not keep one.
6. Publishing triggers the workflow, which builds the `.ipk` and attaches it
   to the release. Check the run finished and the asset is on the release page.

The tag is created by GitHub when the release is published, so there is no
need to tag by hand beforehand.

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
