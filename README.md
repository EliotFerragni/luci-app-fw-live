# luci-app-fw-live 1.0.9

A live view of what your firewall is accepting and refusing, for OpenWrt.
Connections appear as they happen, under **Status → Firewall Live**.

It adds no firewall rules and inspects no packets. It reads two event streams
the kernel already produces and keeps the last few minutes of them in RAM, so
flow offloading is untouched.

![Everything the firewall is doing, newest first](docs/live-overview.png)

Click any address, port, protocol, direction or rule to filter on it. **Pause**
freezes the tail without losing anything; resuming delivers what arrived in the
meantime.

![The same page filtered down to what was refused](docs/live-denied.png)

## Before you start

Accepted and denied traffic reach the page by different routes, which shapes
what you see:

| | comes from | rule name? |
| --- | --- | --- |
| **accepted** connections | the conntrack event stream | no |
| **denied** packets | the firewall's own kernel log | yes |

Two consequences:

- **Accepted connections normally have an empty Rule column.** Conntrack knows
  a connection was allowed, not which rule allowed it. To put a name on one
  kind of traffic, see [Naming a rule](#naming-a-rule).
- **Nothing denied appears until firewall logging is on.** A drop is an event
  that exists only if something logs it. See
  [Turning on firewall logging](#turning-on-firewall-logging).

This is a live view, not a history. Everything is in RAM and nothing survives a
reboot. If you want to know how much each device transferred last Tuesday, that
is a different question and needs a different tool.

## Requirements

`conntrack` and `rpcd-mod-ucode`. On OpenWrt 25.12 and newer:

    apk add conntrack rpcd-mod-ucode

On 24.10 and older:

    opkg install conntrack rpcd-mod-ucode

Developed and verified on 24.10 (mediatek/filogic). Nothing here is specific to
a release, but it has not been run on 25.12 hardware.

## Install

**The prebuilt package**, from the [Releases](../../releases) page. Both are
architecture independent, so the same file works on any target.

OpenWrt 25.12 and newer:

    scp luci-app-fw-live-1.0.9-r1.apk root@192.168.1.1:/tmp/
    ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/luci-app-fw-live-1.0.9-r1.apk'

OpenWrt 24.10 and older:

    scp luci-app-fw-live_1.0.9-1_all.ipk root@192.168.1.1:/tmp/
    ssh root@192.168.1.1 'opkg install /tmp/luci-app-fw-live_1.0.9-1_all.ipk'

**Without a package manager**, copy the source tree to the router and run
`install.sh` on it. `install.sh --remove` undoes it.

    scp -r luci-app-fw-live-src root@192.168.1.1:/tmp/
    ssh root@192.168.1.1 'sh /tmp/luci-app-fw-live-src/install.sh'

Either way, check it came up:

    fwlive-status

## Turning on firewall logging

Accepted connections appear immediately. Denied packets appear only once a
firewall zone has logging on, because until then the kernel writes nothing.

**Settings → Firewall logging** has a checkbox for every zone and every rule.
Start with the `wan` zone: that is where unsolicited traffic arrives.

![The firewall logging panel on the settings page](docs/settings.png)

That panel writes one firewall option, `log`, and nothing else. It decides
whether a line is written, never whether a packet passes, so no box on that
page can lock you out of your router. `fwlive-status` prints the equivalent
`uci` commands if you would rather do it over ssh.

Note that committing applies everything staged for the `firewall` config, so
unsaved changes from elsewhere go in too. The page says when that happened.

**Zone logging does not cover everything.** It covers what your zone *policy*
refuses. A packet refused by a *rule* whose target is REJECT or DROP is decided
by that rule, so it never reaches the zone's logging rule, and having been
refused it produces no conntrack event either. Nothing records it.

That is how netfilter works rather than something this package can fix, so
instead it never lets you forget: rules that refuse traffic without logging it
are marked in red in Settings, reported by `fwlive-status` and shown on the
live page, with the command to fix them.

**Logging costs log volume, not CPU.** OpenWrt's logd keeps a circular buffer
in RAM, so the real price is a chatty firewall pushing everything else out of
`logread` before you get to read it. The current rate is on the status line. If
it is too high, log individual rules instead of whole zones, set `log_limit` on
the zone, or give logd a bigger `log_size`.

## Naming a rule

To put a name on one kind of traffic, accepted or denied, set `option log '1'`
on that firewall rule, either in **Settings → Firewall logging** or with:

    uci set firewall.myrule.log='1'
    uci commit firewall
    /etc/init.d/firewall reload

Its packets then carry its name in the Rule column:

    22:46:29  Rejected  Outbound  TCP  192.168.1.31:46446 -> 198.51.100.111:443  Block-Internet

fw4 writes only the rule's **name** into the log prefix, never the verdict, so
a row like that takes some work: the log line carrying the name and the one
carrying the verdict are matched up, and where the log never states a verdict
the conntrack feed settles it. What cannot be settled either way shows as
**Unknown** rather than being guessed at.

One thing follows that is worth knowing straight away: **a rule can log
traffic it has no intention of refusing.** fw4 turns a rule's destination zone
into a jump rather than a match, so a rule allowing guest to lan matches only
the source, logs, and then checks the destination. Traffic from that source to
anywhere else is logged by the rule and refused further down by the zone. If a
rule's rows include destinations it does not cover, its logging is costing you
volume and telling you nothing.

Everything else about those rows is decided by the two settings below.

## Rows that carry a name but no verdict

Two settings, both on the **Settings** page, decide what becomes of a log line
that names a rule without saying what happened to the packet. The defaults are
right for most people; this section is for when a row is not what you expected.

### `merge_rules`: join a rule's name to its verdict

**On by default.** A packet refused on its way out to the wan is logged twice.
Trimmed to the fields that matter:

    Block-Internet: IN=br-lan OUT=br-wan SRC=192.168.1.31 DST=198.51.100.111
        ID=12938 PROTO=TCP SPT=46446 DPT=443
    reject wan out: IN=br-lan OUT=br-wan SRC=192.168.1.31 DST=198.51.100.111
        ID=12938 PROTO=TCP SPT=46446 DPT=443

The first line names the rule and says nothing about the outcome. The second
states the outcome and names no rule. They are the same packet: same `ID=`,
same addresses, same ports.

**Off**, that is two rows, neither of them the whole story:

    22:46:29  Unknown   Outbound  TCP  192.168.1.31:46446 -> 198.51.100.111:443  Block-Internet
    22:46:29  Rejected  Outbound  TCP  192.168.1.31:46446 -> 198.51.100.111:443

**On**, it is one row that says both things:

    22:46:29  Rejected  Outbound  TCP  192.168.1.31:46446 -> 198.51.100.111:443  Block-Internet

Two more shapes come out of the same pairing.

**Several rules can log one packet**, each writing its own name and none of
them a verdict. Those names become the path the packet took:

    Block-Internet: ... SRC=192.168.1.31 DST=192.168.30.20 ID=65334 PROTO=UDP SPT=53578 DPT=53
    Block-DNS2:     ... SRC=192.168.1.31 DST=192.168.30.20 ID=65334 PROTO=UDP SPT=53578 DPT=53

    09:39:47  Unknown  Local  UDP  192.168.1.31:53578 -> 192.168.30.20:53  Block-Internet > Block-DNS2

Off, that would be two Unknown rows for one packet.

**A zone policy goes on the end of the path rather than onto the rule.** When
the second line is the zone's own forwarding policy, the rule that logged
first did not refuse anything: it matched the source, logged, and let the
packet carry on to the end of the chain.

    Allow-Guest-Device:   ... SRC=192.168.21.58 DST=192.168.1.10 ID=41501 PROTO=TCP SPT=51234 DPT=445
    reject guest forward: ... SRC=192.168.21.58 DST=192.168.1.10 ID=41501 PROTO=TCP SPT=51234 DPT=445

    09:41:02  Rejected  Local  TCP  192.168.21.58:51234 -> 192.168.1.10:445  Allow-Guest-Device > reject guest forward

Reading that as "Allow-Guest-Device rejected this" would be backwards, which
is why the row names the policy that actually refused it.

What is deliberately **not** merged: a broadcast flooded to four bridge ports
is four log lines sharing an `ID=` and differing only in which port they left
by. Those are four forwarding decisions, so they stay four rows.

### `ignore_unknown`: drop rows that never get a verdict

**Off by default.** Some rules log traffic they do not decide. One that only
sets a mark for policy routing logs every packet it marks, and nothing in the
log ever states an outcome for those, so they arrive as Unknown:

    Mark-VPN: IN=br-lan OUT=br-wan SRC=192.168.1.44 DST=198.51.100.20
        ID=9931 PROTO=TCP SPT=39210 DPT=443

**Off**, that packet was allowed, so its conntrack event turns up too and the
two are recognised as one connection. You get one row, accepted and named:

    09:44:10  Accepted  Outbound  TCP  192.168.1.44:39210 -> 198.51.100.20:443  Mark-VPN

**On**, the log event is dropped as it is captured, before anything can pair
it with conntrack. The connection still appears, from the conntrack feed
alone, with nothing in the Rule column:

    09:44:10  Accepted  Outbound  TCP  192.168.1.44:39210 -> 198.51.100.20:443

So turning it on costs you the very thing per rule logging was for. Two
things it does not cost you: rows `merge_rules` already joined to a verdict
are kept, so a rule that both logs and refuses keeps all of its rows; and an
Unknown row never becomes a wrong answer, since a missing conntrack event is
never read as a refusal.

Turn it on for a rule that logs far more than it decides and whose name you do
not need. To hide Unknown rows without losing them, untick **Unknown** in the
verdict filter on the live page instead: that is a browser side filter, and
the events stay in the buffer.

[DEVELOPMENT.md](DEVELOPMENT.md) explains how the two feeds are joined, if the
reasoning behind a particular row matters to you.

## Reading the page

| column | what it is |
| --- | --- |
| Time | when the event was read |
| Verdict | accepted, dropped, rejected or unknown. Denied rows carry a red edge |
| Direction | inbound, outbound or local, with the interfaces underneath |
| Protocol | TCP, UDP, ICMP or the protocol number, plus flags or type/code |
| Source | host name over address, resolved in your browser |
| Destination | the same, for the far end |
| Rule | which rules logged the packet, in the order it met them. Empty for most accepted connections |

A Rule cell can hold more than one name, separated by `>`. Those are the rules
that logged the packet as it travelled through the ruleset, and they are not
all claims about the verdict: a rule logged through `option log` writes only
its own name, while the prefixes fw4 generates itself, like
`reject guest forward`, do state an outcome. So a row reading
`Allow-Guest-Device > reject guest forward` means that rule saw the packet and
the guest zone policy is what refused it. [Rows that carry a name but no
verdict](#rows-that-carry-a-name-but-no-verdict) has the log lines behind each
shape of that column.

The interfaces under Direction are written `bridge/port`, so `br-lan/wlan0`
means the packet arrived on the `br-lan` bridge from the `wlan0` radio. That is
often the most useful thing on the row: it tells you which access point a
client is actually on.

Direction compares both ends against the prefixes this router owns, so a
scanner on the same subnet as your wan address reads as Local.

The summary line counts the whole buffer rather than the page, so it stays
meaningful while a filter is on.

## Configuration

Everything is editable under **Status → Firewall Live → Settings**, which also
shows whether the service is alive and what it would take to fix either feed.
Save & Apply restarts the service.

The same options live in `/etc/config/fw-live`:

| option | default | meaning |
| --- | --- | --- |
| `enabled` | `1` | master switch for the capture service |
| `accepts` | `1` | capture accepted connections from conntrack |
| `denies` | `1` | capture denied packets from the firewall log |
| `buffer_size` | `5000` | events kept per feed, in RAM only |
| `max_rate` | `200` | events/second per feed before the excess is shed |
| `poll_interval` | `2` | how often the page asks for new events, seconds |
| `ignore_local` | `0` | drop events with both ends on a local network |
| `local_network` | every interface | list: uci network interfaces that count as local |
| `local_subnet` | none | list: extra local prefixes, as `address/length` |
| `merge_rules` | `1` | fold a rule's log line into the verdict line for the same packet ([examples](#merge_rules-join-a-rules-name-to-its-verdict)) |
| `ignore_unknown` | `0` | drop log events whose prefix does not state a verdict ([examples](#ignore_unknown-drop-rows-that-never-get-a-verdict)) |
| `time_format` | `auto` | clock: `auto`, `24` or `12` |
| `date_format` | `auto` | date order: `auto`, `dmy` or `mdy` |

    uci set fw-live.main.buffer_size='20000'
    uci commit fw-live
    /etc/init.d/fw-live reload

At the default of 5000 events per feed the buffer costs roughly 1.2 MB of RAM
and holds anywhere from a few minutes to several hours, depending on how busy
the network is.

`max_rate` is a safety valve rather than a tuning knob: if a log rule starts
matching far more than it should, the excess is dropped and counted rather than
allowed to fill RAM.

**What counts as local** decides the Direction column and what `ignore_local`
leaves out. Every address the router holds is found automatically, so both list
options are usually unset. `local_subnet` is the one worth knowing about: a
tunnel gives the router one address on the link while the site on the far side
is a route, so a VPN subnet is invisible until you name it.

## Troubleshooting

Start here. It reports the service, both feeds, the buffer and anything
discarded, and prints the commands to fix whichever feed is not working:

    fwlive-status

If that is not enough:

- **Nothing denied appears.** `uci show firewall | grep -i log`, and if nothing
  comes back no zone has logging on. If one does, check the kernel is writing
  the lines with `logread -e 'IN='`.
- **Nothing accepted appears.** `cat /proc/sys/net/netfilter/nf_conntrack_events`
  must not be `0`, or the kernel emits no events at all.
- **Direction says Unknown for everything.** `/tmp/fw-live/subnets` is empty;
  run `/usr/bin/fwlive-subnets` by hand and read the error.
- **The page is missing from the menu.** Clear the LuCI caches and restart
  rpcd, then log out and back in: `rm -rf /tmp/luci-indexcache*
  /tmp/luci-modulecache && /etc/init.d/rpcd restart`.
- **The page is there but empty.** `ubus call luci_fw_live status '{}'`, and if
  the object is missing `logread -e rpcd` says why.

## Installed files

    /etc/config/fw-live                                     configuration
    /etc/init.d/fw-live                                     procd service
    /usr/bin/fwlive-follow                                  both feeds, one parser
    /usr/bin/fwlive-query                                   filters the buffer into JSON
    /usr/bin/fwlive-status                                  diagnostics
    /usr/bin/fwlive-subnets                                 local prefix cache
    /usr/bin/fwlive-logging                                 the firewall logging checkboxes
    /usr/share/rpcd/ucode/luci.fw_live.uc                   ubus backend
    /usr/share/rpcd/acl.d/luci-app-fw-live.json             ACL
    /usr/share/luci/menu.d/luci-app-fw-live.json            menu entry
    /www/luci-static/resources/view/fw-live/main.js         the live page
    /www/luci-static/resources/view/fw-live/settings.js     the settings page
    /tmp/fw-live/                                           the buffer, in RAM

Working on it rather than running it? See [DEVELOPMENT.md](DEVELOPMENT.md).

## How this was written

Claude, Anthropic's coding agent, wrote this package: the capture service, the
parser, the ucode backend, the LuCI views, the build scripts and this README.
The screenshots are the real page rendered against synthetic events rather than
grabs from a live router, so the device names and addresses in them are
invented. The maintainer set the direction, reviewed the result and runs it on
the target hardware.

None of that changes what you should do before installing a package from a
stranger on a router you care about: read the scripts. They are deliberately
short, and they are listed above.
