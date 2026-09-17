#!/usr/bin/env python3
"""Run the LuCI view on a laptop, with no router and no firewall.

Nothing here reimplements the page. It writes synthetic events in the format
the follower spools, filters them with the real fwlive-query, and runs the
real main.js behind stubs shaped like LuCI's E, rpc, uci, view, poll and
network.

    python3 tools/preview.py                  # serve the page, click around
    python3 tools/preview.py --live           # and keep new events arriving
    python3 tools/preview.py --dark           # in LuCI's dark theme
    python3 tools/preview.py --screenshots    # rewrite docs/*.png instead

--dark, --time-format and --date-format apply to both, so a screenshot shows
the same page serving would.

Served, the page is on http://127.0.0.1:8099 and its rpc calls run the query
script for real, so the verdict, direction, protocol and search filters behave
as they do on a router. --live appends new events on a timer, which is what
exercises the tail, the cursors and the pause button. The page reports what it
drew, and anything it throws, to this terminal.

--screenshots skips the server and writes the images in docs/ through headless
Firefox. Those pages answer every rpc call from one baked fixture, so they need
no server, and nothing in them responds.

Needs python3-pil, and firefox for --screenshots. busybox is used for awk and
date when it is installed, which is what the router runs; otherwise the system
ones stand in.

Every window ends "now", so no two runs produce identical pixels: the clock
labels move. Regenerate the images when the page changed, not out of habit.
"""

import argparse
import json
import os
import pathlib
import random
import re
import shutil
import string
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
FILES = ROOT / "package/luci-app-fw-live/files"
QUERY = FILES / "usr/bin/fwlive-query"
LOGGING = FILES / "usr/bin/fwlive-logging"
SETTINGS = FILES / "www/luci-static/resources/view/fw-live/settings.js"
VIEW = FILES / "www/luci-static/resources/view/fw-live/main.js"
DOCS = ROOT / "docs"

WAN = "203.0.113.7"
WAN6 = "2001:db8:1:1::1"

# A plausible household. weight is how often the device opens a connection.
HOSTS = [
    ("192.168.1.24", "laptop", 10),
    ("192.168.1.31", "phone", 8),
    ("192.168.1.40", "apple-tv", 5),
    ("192.168.1.50", "nas", 4),
    ("192.168.1.62", "pi-hole", 6),
    ("192.168.1.77", "doorbell-cam", 3),
    ("192.168.1.90", "workstation", 9),
]

# Where those connections go, and on what.
DESTS = [
    ("198.51.100.133", 443, "tcp"),
    ("198.51.100.160", 443, "tcp"),
    ("198.51.100.100", 53, "udp"),
    ("198.51.100.161", 53, "udp"),
    ("198.51.100.162", 123, "udp"),
    ("198.51.100.163", 443, "tcp"),
    ("192.168.1.1", 53, "udp"),
    ("192.168.1.1", 22, "tcp"),
    ("198.51.100.100", 0, "icmp"),
]

# What the internet tries on the wan address while nobody asked it to.
SCANNERS = [
    ("198.51.100.23", 22, "tcp", "reject"),
    ("198.51.100.90", 3389, "tcp", "drop"),
    ("192.0.2.44", 23, "tcp", "drop"),
    ("203.0.113.199", 5060, "udp", "drop"),
    ("198.51.100.171", 445, "tcp", "drop"),
    ("192.0.2.180", 0, "icmp", "drop"),
]

RULES = {"reject": "reject wan in", "drop": "drop wan in"}

# What --status prints, as the ucode backend parses it into key/value pairs.
STATUS = {"status": {
    "service": "running (pid 4711)",
    "capture": "accepts on, denies on",
    "conntrack events": "available, 0 buffered",
    "firewall logging": "enabled on zone wan",
    "logged rules": "1 with option log set",
    "unlogged denies": "none, every rule that refuses traffic also logs it",
    "buffered": "0 accepted, 0 denied (max 5000 each)",
    "oldest event": "",
    "discarded": "0 (buffer), 0 (rate limit)",
    "rate limit": "200 events/s per feed",
    "poll interval": "2 s",
    "ignore local": "no",
    "ignore unknown": "no",
    "merge rules": "yes, 61 rows carry a rule name they would not otherwise have",
    "event rate": "7.6/s accepted, 3.6/s denied",
    "local prefixes": "6: 192.168.1.1/24, 10.0.30.1/24, 192.168.50.0/24, "
                      "fd00:abc::1/64, ::1/128, fe80::/10",
}}

# Close enough to LuCI's bootstrap themes to be honest about the layout. The
# page brings its own styling for the chips and the row emphasis.
LIGHT = dict(scheme="light", bg="#f6f6f6", panel="#ffffff", border="#e3e3e3",
             rule="#dcdcdc", text="#212529", muted="#666666", label="#444444",
             link="#0069d9", row="#fafafa", line="#ededed", head="#555555",
             headrule="#dddddd", field="#ffffff", fieldborder="#cccccc",
             btn="#0069d9", btntext="#ffffff")
DARK = dict(scheme="dark", bg="#101214", panel="#191c20", border="#2a2f36",
            rule="#2a2f36", text="#d7dde3", muted="#98a1aa", label="#b4bcc4",
            link="#6cb2ff", row="#1d2126", line="#262b31", head="#a7afb8",
            headrule="#333a42", field="#23272d", fieldborder="#3a4048",
            btn="#2a6fc4", btntext="#ffffff")

CSS = string.Template("""
:root { color-scheme: $scheme }
body { margin: 0; background: $bg; color: $text;
       font: 14px/1.5 -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif }
#page { max-width: 1180px; margin: 0 auto; padding: 18px 22px 26px }
.cbi-map > h2 { font-size: 26px; font-weight: 400; margin: 0 0 14px; padding-bottom: 8px;
                border-bottom: 1px solid $rule; color: $link }
.cbi-section { background: $panel; border: 1px solid $border; border-radius: 3px;
               padding: 14px 16px; margin-bottom: 14px }
.cbi-section-descr { color: $muted; font-size: 13px }
label { font-size: 13px; color: $label }
select.cbi-input-select, input.cbi-input-text {
    font: inherit; font-size: 13px; padding: 4px 6px;
    border: 1px solid $fieldborder; border-radius: 3px; background: $field; color: $text }
button.cbi-button { font: inherit; font-size: 13px; padding: 4px 14px; border-radius: 3px;
                    border: 1px solid $btn; background: $btn; color: $btntext; cursor: pointer }
a { color: $link; text-decoration: none }
a:hover { text-decoration: underline }
.table { display: table; width: 100%; border-collapse: collapse; margin-top: 4px }
.tr { display: table-row }
.th, .td { display: table-cell; padding: 6px 10px; border-bottom: 1px solid $line;
           vertical-align: top; font-size: 13px }
.table-titles .th { font-weight: 600; color: $head; border-bottom: 2px solid $headrule;
                    font-size: 12px; text-align: left }
.tr:nth-child(even) { background: $row }
.alert-message { padding: 10px 12px; border-radius: 3px; background: rgba(217,128,50,0.15) }
""")

# The view is a LuCI module body, so it runs as-is given the same globals LuCI
# passes it. E()'s contract matters: function-valued attributes are listeners.
BOOT = """
const _ = (s) => s;
function append(node, child) {
	if (child === null || child === undefined || child === '') return;
	if (Array.isArray(child)) { child.forEach((c) => append(node, c)); return; }
	node.appendChild(child instanceof Node ? child : document.createTextNode('' + child));
}
function E(tag, attrs, children) {
	const node = document.createElement(tag);
	if (attrs && (typeof attrs !== 'object' || Array.isArray(attrs) || attrs instanceof Node)) {
		children = attrs; attrs = null;
	}
	for (const k in (attrs || {})) {
		const v = attrs[k];
		if (v === null || v === undefined) continue;
		if (typeof v === 'function') node.addEventListener(k, v);
		else node.setAttribute(k, v);
	}
	append(node, children);
	return node;
}
const view = { extend: (proto) => proto };
const L = { resolveDefault: (p, d) => p.catch(() => d) };
const network = { getHostHints: () => Promise.resolve({
	getHostnameByIPAddr: (a) => (window.FIXTURE.hosts || {})[a] || null,
	getHostnameByIP6Addr: (a) => (window.FIXTURE.hosts || {})[a] || null
}) };
"""

# A screenshot is one fixed state, so every call answers from the same fixture
# and nothing polls.
STUBS_FIXED = """
const poll = { add: () => {} };
const rpc = { declare: (o) => () => Promise.resolve(
	o.method === 'status' ? window.FIXTURE.status : window.FIXTURE.events) };
const uci = {
	load: () => Promise.resolve(),
	get: (cfg, sec, opt) => (window.FIXTURE.uci || {})[opt]
};
"""

# Served, the calls go to the real query script, so the filters do something
# and the cursors are the real ones.
STUBS_LIVE = """
const poll = { add: (fn, s) => window.setInterval(fn, Math.max(1, s) * 1000) };
let pending = { status: window.FIXTURE.status, events: window.FIXTURE.events };
const rpc = { declare: (o) => function () {
	if (pending[o.method]) {
		const first = pending[o.method];
		pending[o.method] = null;
		return Promise.resolve(first);
	}
	const names = o.params || [];
	const q = new URLSearchParams();
	for (let i = 0; i < names.length; i++)
		q.set(names[i], arguments[i] === undefined ? '' : arguments[i]);
	return fetch('/' + o.method + '?' + q.toString()).then((r) => r.json()).then(function (d) {
		if (o.method === 'events')
			report('drew ' + (d.events || []).length + ' of ' + d.matched + ' matching, ' +
			       'cursor log=' + d.seq.log + ' ct=' + d.seq.ct);
		return d;
	});
} };
const uci = {
	values: window.FIXTURE.uci || {},
	load: function () {
		return fetch('/uci').then((r) => r.json()).then((v) => { uci.values = v; });
	},
	get: function (cfg, sec, opt) { return uci.values[opt]; }
};
function report(msg) { fetch('/log?m=' + encodeURIComponent(msg)); }
window.addEventListener('error', (e) => report('error: ' + e.message));
window.addEventListener('unhandledrejection', (e) => report('rejected: ' + e.reason));
"""


class Spools:
    """Writes event lines the way the follower does, and keeps growing them."""

    def __init__(self, work):
        self.dir = work / "run"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.seq = {"log": 0, "ct": 0}
        self.lock = threading.Lock()
        self.rng = random.Random(11)
        (self.dir / "subnets").write_text(
            "4\t127.0.0.1\t8\n4\t192.168.1.1\t24\n4\t%s\t24\n"
            "6\t::1\t128\n6\t%s\t64\n6\tfe80::\t10\n" % (WAN, WAN6))
        for src in ("log", "ct"):
            (self.dir / ("events.%s" % src)).write_text("")
            (self.dir / ("stats.%s" % src)).write_text("shed 0\ntrimmed 0\nseq 0\n")

    def line(self, ts, src, verdict, proto, saddr, sport, daddr, dport,
             iif, oif, direction, rule, extra):
        self.seq[src] += 1
        return "\t".join(str(x) for x in (
            ts, self.seq[src], src, verdict, 4, proto, saddr, sport or "-",
            daddr, dport or "-", iif, oif, direction, rule, extra))

    def accept(self, ts):
        saddr, _name, _w = self.rng.choices(HOSTS, weights=[h[2] for h in HOSTS])[0]
        daddr, dport, proto = self.rng.choice(DESTS)
        local = daddr.startswith("192.168.")
        return self.line(ts, "ct", "accept", proto, saddr,
                         self.rng.randint(32768, 60999), daddr, dport or "-",
                         "-", "-", "local" if local else "out", "-",
                         "8/0" if proto == "icmp" else "-")

    def deny(self, ts):
        saddr, dport, proto, verdict = self.rng.choice(SCANNERS)
        # One rule carries a name, which is what setting option log on a
        # single uci rule gets you.
        rule = "Block-Telnet" if dport == 23 else RULES[verdict]
        return self.line(ts, "log", verdict, proto, saddr,
                         self.rng.randint(1024, 65535), WAN, dport or "-",
                         "eth1", "-", "in", rule,
                         "SYN" if proto == "tcp" else ("8/0" if proto == "icmp" else "-"))

    def backfill(self, minutes):
        """A window of history ending now, so the page opens with something."""
        now = int(time.time())
        rows = {"log": [], "ct": []}
        for ts in range(now - minutes * 60, now):
            for _ in range(self.rng.choices([0, 1, 2, 3], weights=[30, 40, 20, 10])[0]):
                rows["ct"].append(self.accept(ts))
            if self.rng.random() < 0.08:
                rows["log"].append(self.deny(ts))
        for src, lines in rows.items():
            (self.dir / ("events.%s" % src)).write_text("\n".join(lines) + "\n")
        return sum(len(v) for v in rows.values())

    def tick(self):
        """One second of new traffic, appended the way the follower does."""
        now = int(time.time())
        with self.lock:
            for _ in range(self.rng.choices([0, 1, 2], weights=[25, 50, 25])[0]):
                with (self.dir / "events.ct").open("a") as f:
                    f.write(self.accept(now) + "\n")
            if self.rng.random() < 0.25:
                with (self.dir / "events.log").open("a") as f:
                    f.write(self.deny(now) + "\n")


# A firewall shaped like the one this was developed against: several zones,
# and rules including two that refuse traffic without logging it.
FIREWALL = """firewall.@defaults[0]=defaults
firewall.@defaults[0].input='REJECT'
firewall.@zone[0]=zone
firewall.@zone[0].name='lan'
firewall.@zone[0].log='1'
firewall.@zone[1]=zone
firewall.@zone[1].name='wan'
firewall.@zone[1].log='1'
firewall.iot=zone
firewall.iot.name='iot'
firewall.@zone[3]=zone
firewall.@zone[3].name='guest'
firewall.@rule[0]=rule
firewall.@rule[0].name='Allow-DHCP-Renew'
firewall.@rule[0].target='ACCEPT'
firewall.@rule[1]=rule
firewall.@rule[1].name='Allow-Ping'
firewall.@rule[1].target='ACCEPT'
firewall.@rule[2]=rule
firewall.@rule[2].name='Block-Telnet'
firewall.@rule[2].target='REJECT'
firewall.blocksmb=rule
firewall.blocksmb.name='Block-SMB-Out'
firewall.blocksmb.target='DROP'
firewall.@rule[4]=rule
firewall.@rule[4].name='Watched-Already'
firewall.@rule[4].target='REJECT'
firewall.@rule[4].log='1'
firewall.@rule[5]=rule
firewall.@rule[5].name='Block-Internet'
firewall.@rule[5].target='MARK'
"""

# Matching is literal, because a section id like @rule[3] is not a regex.
UCI_STUB = r"""#!/bin/sh
F=$FAKE_UCI
while [ "$1" = "-q" ]; do shift; done
case "$1" in
	show)    cat "$F" ;;
	get)     awk -v k="$2=" 'index($0, k) == 1 { sub(/^[^=]*=/, "", $0); gsub(/^\047|\047$/, "", $0); print; f = 1; exit } END { exit !f }' "$F" ;;
	set)     k=${2%%=*}; v=${2#*=}
	         awk -v k="$k=" 'index($0, k) != 1' "$F" > "$F.n"
	         printf "%s='%s'
" "$k" "$v" >> "$F.n"; mv "$F.n" "$F" ;;
	delete)  awk -v k="$2=" 'index($0, k) != 1' "$F" > "$F.n"; mv "$F.n" "$F" ;;
	commit|changes|revert) : ;;
	*)       exit 1 ;;
esac
exit 0
"""


def host_map():
    return {ip: name for ip, name, _w in HOSTS}


def run_query(work, env_path, args):
    env = dict(os.environ)
    env["FWLIVE_RUN"] = str(work / "run")
    if shutil.which("busybox"):
        env["PATH"] = "%s:%s" % (env_path, env["PATH"])
    sh = "busybox" if shutil.which("busybox") else "sh"
    cmd = ([sh, "sh"] if sh == "busybox" else [sh]) + [str(QUERY)] + [str(a) for a in args]
    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if res.returncode != 0 or not res.stdout.strip():
        sys.exit("query failed: %s" % (res.stderr.strip() or "no output"))
    return json.loads(res.stdout)


def status_for(data):
    st = json.loads(json.dumps(STATUS))
    b = data.get("buffered", {})
    st["status"]["buffered"] = "%d accepted, %d denied (max 5000 each)" % (
        b.get("ct", 0), b.get("log", 0))
    st["status"]["conntrack events"] = "available, %d buffered" % b.get("ct", 0)
    oldest = data.get("oldest", 0)
    st["status"]["oldest event"] = (
        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(oldest)) +
        " (%ds ago)" % max(0, int(time.time()) - oldest)) if oldest else "none buffered yet"
    return st


def run_logging(work, env_path, args):
    """The real fwlive-logging, against the fake firewall config."""
    env = dict(os.environ)
    env["FAKE_UCI"] = str(work / "firewall")
    env["FWLIVE_FW_INIT"] = str(work / "bin" / "firewall-init")
    env["PATH"] = "%s:%s" % (env_path, env["PATH"])
    sh = "busybox" if shutil.which("busybox") else "sh"
    cmd = ([sh, "sh"] if sh == "busybox" else [sh]) + [str(LOGGING)] + args
    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if not res.stdout.strip():
        return {"error": res.stderr.strip() or "no output"}
    return json.loads(res.stdout)


def write_page(work, name, data, filters=None, paused=False, live=False,
               formats=None, dark=False):
    src = VIEW.read_text()
    if "</script" in src:
        sys.exit("the view contains a </script>, which cannot be inlined as-is")
    fixture = {"status": status_for(data), "events": data, "hosts": host_map(),
               "uci": formats or {"time_format": "auto", "date_format": "auto",
                                  "poll_interval": "2"}}
    # the shape and version main.js writes, so the page reads it back rather
    # than discarding it as state from an older build
    filters = filters or {"verdict": ["accept", "drop", "reject", "unknown"],
                          "dir": "", "proto": "", "search": ""}
    filters = dict(filters, v=1)
    page = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Firewall Live</title>
<style>%s</style></head><body><div id="page"></div>
<script id="viewsrc" type="text/plain">%s</script>
<script>
window.FIXTURE = %s;
try {
	localStorage.setItem('fw-live.filters', %s);
	localStorage.setItem('fw-live.paused', %s);
} catch (e) {}
%s
const mod = new Function('view', 'rpc', 'poll', 'uci', 'network', 'E', '_', 'L',
	document.getElementById('viewsrc').textContent)(view, rpc, poll, uci, network, E, _, L);
mod.load().then(function(res) {
	document.getElementById('page').appendChild(mod.render(res));
	if (typeof report === 'function') report('rendered');
});
</script></body></html>""" % (
        CSS.substitute(DARK if dark else LIGHT), src, json.dumps(fixture),
        json.dumps(json.dumps(filters)), json.dumps("1" if paused else "0"),
        BOOT + (STUBS_LIVE if live else STUBS_FIXED))
    path = work / ("%s.html" % name)
    path.write_text(page)
    return path


# The settings view is a LuCI form page. form is stubbed just far enough to
# render what each option would show, which is not really the point: the point
# is the firewall logging panel below it, which is plain DOM and talks to the
# real fwlive-logging over the same rpc shape LuCI uses.
SETTINGS_BASE = """
const poll = { add: () => {} };
const ui = {
	addNotification: function (title, node, kind) {
		document.getElementById('notices').appendChild(
			E('div', { 'class': 'notice ' + (kind || 'info') }, node));
		report('notification: ' + (node.textContent || ''));
	},
	showModal: function (title, children) {
		ui._modal = E('div', { 'class': 'notice' }, [ E('h4', {}, title) ].concat(children));
		document.getElementById('notices').appendChild(ui._modal);
	},
	hideModal: function () { if (ui._modal) ui._modal.remove(); }
};
const form = {
	NamedSection: 'NamedSection', DummyValue: 'DummyValue', Value: 'Value',
	Flag: 'Flag', ListValue: 'ListValue', Button: 'Button',
	DynamicList: 'DynamicList',
	Map: function (cfg, title, descr) {
		this.secs = [];
		this.section = function (kind, name, type, label) {
			const sec = { label: label, opts: [] };
			sec.option = function (t, oname, olabel, odescr) {
				const o = { type: t, name: oname, label: olabel, descr: odescr,
				            choices: [], depends: function () {} };
				o.value = function (k, lbl) { o.choices.push([ k, lbl ]); };
				sec.opts.push(o);
				return o;
			};
			this.secs.push(sec);
			return sec;
		};
		this.render = function () {
			const node = E('div', { 'class': 'cbi-map' }, [ E('h2', {}, title),
				E('p', { 'class': 'cbi-section-descr' }, descr) ]);
			for (const sec of this.secs) {
				const box = E('div', { 'class': 'cbi-section' }, [ E('h3', {}, sec.label) ]);
				for (const o of sec.opts) {
					let v = '';
					if (typeof o.cfgvalue === 'function') { try { v = o.cfgvalue(); } catch (e) { v = ''; } }
					const val = E('div', {});
					// close enough to what each option type puts on screen for
					// the page to be worth looking at; the real thing is CBI
					if (o.type === 'Flag') {
						const b = E('input', { type: 'checkbox' });
						b.checked = (o.default === '1');
						val.appendChild(b);
					}
					else if (o.type === 'ListValue') {
						val.appendChild(E('select', { 'class': 'cbi-input-select' },
							o.choices.map(function (c) { return E('option', { value: c[0] }, c[1]); })));
					}
					else if (o.type === 'Value') {
						val.appendChild(E('input', { type: 'text', 'class': 'cbi-input-text',
							placeholder: o.placeholder || '' }));
					}
					else if (o.type === 'Button') {
						val.appendChild(E('button', { 'class': 'cbi-button' }, o.inputtitle || _('Go')));
					}
					else if (o.type === 'NetworkSelect') {
						// luci-base draws each network with its device; the shape
						// is what matters here, not the icons
						val.appendChild(E('div', { 'class': 'cbi-dropdown', style:
							'border:1px solid rgba(128,128,128,0.4);border-radius:3px;' +
							'padding:4px 8px;display:inline-block;min-width:24em' },
							FAKE_NETWORKS.map(function (n) {
								return E('span', { style: 'margin-right:10px;opacity:0.75' }, n + ':');
							}).concat([ E('span', { style: 'float:right;opacity:0.5' }, '\u25be') ])));
					}
					else if (o.type === 'DynamicList') {
						val.appendChild(E('input', { type: 'text', 'class': 'cbi-input-text',
							placeholder: o.placeholder || '' }));
						val.appendChild(E('button', { 'class': 'cbi-button', style: 'margin-left:6px' }, '+'));
					}
					else if (o.rawhtml) val.innerHTML = v;
					else val.textContent = String(v);
					box.appendChild(E('div', { 'class': 'cbi-row' },
						[ E('div', { 'class': 'cbi-label' }, o.label || o.name), val ]));
					if (o.descr)
						box.appendChild(E('div', { 'class': 'cbi-row' },
							[ E('div', { 'class': 'cbi-label' }, ''),
							  E('div', { style: 'opacity:0.6;font-size:12px;max-width:62em' }, o.descr) ]));
				}
				node.appendChild(box);
			}
			return Promise.resolve(node);
		};
	}
};
"""

# Served, the calls are real, so Apply genuinely rewrites the firewall config.
SETTINGS_RPC_LIVE = """
const rpc = { declare: (o) => function () {
	const names = o.params || [];
	const q = new URLSearchParams();
	for (let i = 0; i < names.length; i++)
		q.set(names[i], arguments[i] === undefined ? '' : arguments[i]);
	return fetch('/' + o.method + '?' + q.toString()).then((r) => r.json());
} };
function report(msg) { fetch('/log?m=' + encodeURIComponent(msg)); }
window.addEventListener('error', (e) => report('error: ' + e.message));
window.addEventListener('unhandledrejection', (e) => report('rejected: ' + e.reason));
"""

# A screenshot is taken the moment the page loads, so anything fetched over
# the network arrives too late to be in it. Same split as the live page: for
# an image every call answers from an embedded fixture, synchronously.
SETTINGS_RPC_FIXED = """
const rpc = { declare: (o) => function () {
	return Promise.resolve(window.FIXTURE[o.method] || {});
} };
function report(msg) {
	// into the page, because an image is the only output this mode has
	if (msg.indexOf('failed') >= 0 || msg.indexOf('error') >= 0)
		document.getElementById('notices').appendChild(
			E('pre', { style: 'color:#b03a39;white-space:pre-wrap' }, msg));
}
window.addEventListener('error', (e) => report('error: ' + e.message));
window.addEventListener('unhandledrejection', (e) => report('rejected: ' + e.reason));
"""

SETTINGS_CSS = """
.cbi-row { display: flex; gap: 10px; padding: 3px 0; font-size: 13px }
.cbi-label { min-width: 240px; opacity: 0.75 }
.notice { padding: 8px 10px; margin: 6px 0; border-radius: 3px; font-size: 13px;
          background: rgba(120,160,220,0.18) }
.notice.error { background: rgba(194,80,79,0.2) }
.notice.warning { background: rgba(217,128,50,0.2) }
.fwl-warn { color: #b03a39 }
h3 { margin: 16px 0 6px; font-size: 16px }
h4 { margin: 14px 0 4px; font-size: 14px }
button.cbi-button[disabled] { opacity: 0.5; cursor: default }
"""


def write_settings_page(work, dark=False, fixture=None):
    src = SETTINGS.read_text()
    if "</script" in src:
        sys.exit("the settings view contains a </script>, which cannot be inlined as-is")
    page = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Firewall Live settings</title>
<style>%s%s</style></head><body><div id="page"></div><div id="notices"></div>
<script id="viewsrc" type="text/plain">%s</script>
<script>
window.FIXTURE = %s;
%s
// The names the settings view requires, in the order it lists them. network
// comes from the shared stubs above, which both pages get.
// What the settings view requires, in the order it lists them. tools.widgets
// is luci-base's, and only the one control used from it is stubbed.
const FAKE_NETWORKS = [ 'lan', 'guest', 'wan', 'wg0' ];
const widgets = { NetworkSelect: 'NetworkSelect' };
const mod = new Function('view', 'form', 'widgets', 'rpc', 'ui', 'E', '_', 'L',
	document.getElementById('viewsrc').textContent)(view, form, widgets, rpc, ui, E, _, L);
mod.load().then(function (res) {
	return mod.render(res);
}).then(function (node) {
	document.getElementById('page').appendChild(node);
	report('settings rendered');
}).catch(function (e) {
	// a view that throws leaves a blank page and says nothing, which is the
	// single most annoying way to develop one
	const msg = (e && e.stack) || ('' + e);
	report('render failed: ' + msg);
	document.getElementById('page').appendChild(
		E('pre', { style: 'color:#b03a39;white-space:pre-wrap' }, 'render failed: ' + msg));
});
</script></body></html>""" % (CSS.substitute(DARK if dark else LIGHT), SETTINGS_CSS,
                              src, json.dumps(fixture or {}),
                              BOOT + SETTINGS_BASE + (SETTINGS_RPC_FIXED if fixture else SETTINGS_RPC_LIVE))
    path = work / ("settings-shot.html" if fixture else "settings.html")
    path.write_text(page)
    return path


def shoot(work, page, out, height=1600):
    """Firefox headless, then trim the background below the content."""
    from PIL import Image
    raw = work / ("%s.raw.png" % out.stem)
    profile = work / "profile"
    profile.mkdir(exist_ok=True)
    subprocess.run(["firefox", "--headless", "-no-remote", "-profile", str(profile),
                    "--window-size=1280,%d" % height, "--screenshot", str(raw), page.as_uri()],
                   capture_output=True, timeout=300)
    if not raw.exists():
        sys.exit("firefox produced no screenshot for %s" % page.name)
    im = Image.open(raw).convert("RGB")
    w, h = im.size
    bg = im.getpixel((5, h - 5))
    last = h - 1
    while last > 0 and all(im.getpixel((x, last)) == bg for x in range(0, w, 7)):
        last -= 1
    im = im.crop((0, 0, w, min(h, last + 20)))
    im.convert("P", palette=Image.ADAPTIVE, colors=128).save(out, optimize=True)
    print("  %-28s %sx%s  %d KiB" % (out.name, im.width, im.height, out.stat().st_size // 1024))


def serve(work, env_path, spools, port, formats, dark, live):
    """Hand the page the real query output, so its filters actually filter."""
    import http.server
    import urllib.parse

    first = run_query(work, env_path, [200, 0, 0, "", "", "", ""])
    page = write_page(work, "live", first, live=True, formats=formats, dark=dark).read_bytes()
    settings_page = write_settings_page(work, dark=dark).read_bytes()

    if live:
        def feed():
            while True:
                time.sleep(1)
                spools.tick()
        threading.Thread(target=feed, daemon=True).start()

    class Handler(http.server.BaseHTTPRequestHandler):
        def send_json(self, obj):
            body = json.dumps(obj).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(url.query)
            arg = lambda k, d="": (q.get(k) or [d])[0]
            if url.path == "/events":
                # the order the view's rpc.declare lists its params in
                self.send_json(run_query(work, env_path, [
                    arg("limit", 200), arg("after_log", 0), arg("after_ct", 0),
                    arg("verdict"), arg("proto"), arg("dir"), arg("search")]))
            elif url.path == "/status":
                self.send_json(status_for(run_query(work, env_path, [1, 0, 0, "", "", "", ""])))
            elif url.path == "/log":
                print("  page: %s" % arg("m"), file=sys.stderr, flush=True)
                self.send_response(204)
                self.end_headers()
            elif url.path == "/uci":
                self.send_json(formats)
            elif url.path == "/logging":
                self.send_json(run_logging(work, env_path, ["--list"]))
            elif url.path == "/set_logging":
                # the same shape the ucode backend enforces before anything
                # reaches a command line, spelled exactly as it is there
                args = [a for a in arg("set").split(",")
                        if re.match(r"^[]A-Za-z0-9_@[-]{1,64}=[01]$", a)]
                if not args:
                    self.send_json({"error": "Nothing valid to change."})
                else:
                    self.send_json(run_logging(work, env_path, ["--set"] + args[:64]))
            elif url.path in ("/settings", "/settings.html"):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(settings_page)))
                self.end_headers()
                self.wfile.write(settings_page)
            elif url.path in ("/", "/index.html"):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)
            else:
                self.send_error(404)

        def log_message(self, fmt, *a):
            # one compact line per call, so it is obvious what the page asked for
            print("  %s" % (fmt % a), file=sys.stderr, flush=True)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("serving the view on http://127.0.0.1:%d  (ctrl-c to stop)" % srv.server_address[1],
          flush=True)
    print("  settings, including the firewall logging panel, on /settings", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--screenshots", action="store_true",
                    help="write docs/*.png with headless Firefox instead of serving")
    ap.add_argument("--port", type=int, default=8099, metavar="N",
                    help="port to serve on (default 8099)")
    ap.add_argument("--minutes", type=int, default=45, metavar="N",
                    help="minutes of synthetic events to start with (default 45)")
    ap.add_argument("--live", action="store_true",
                    help="keep appending new events while serving, so the tail, the "
                         "cursors and the pause button do something")
    ap.add_argument("--work", metavar="DIR",
                    help="build in DIR and leave it there, rather than in a temporary "
                         "directory that is deleted on exit; the synthetic spools in it "
                         "can be queried by hand with FWLIVE_RUN=DIR/run")
    ap.add_argument("--dark", action="store_true",
                    help="render in a dark theme, like LuCI's dark one")
    ap.add_argument("--time-format", default="auto", choices=("auto", "24", "12"),
                    help="what the page is told the clock setting is")
    ap.add_argument("--date-format", default="auto", choices=("auto", "dmy", "mdy"),
                    help="what the page is told the date order setting is")
    args = ap.parse_args()

    if args.screenshots and not shutil.which("firefox"):
        sys.exit("firefox is needed to rasterize the pages")
    if args.screenshots:
        try:
            import PIL  # noqa: F401
        except ImportError:
            sys.exit("python3-pil is needed")

    work = (pathlib.Path(args.work).resolve() if args.work
            else pathlib.Path(tempfile.mkdtemp(prefix="fwlive-preview-")))
    work.mkdir(parents=True, exist_ok=True)
    env_path = str(work / "bin")
    if shutil.which("busybox"):
        binned = work / "bin"
        binned.mkdir(exist_ok=True)
        for tool in ("awk", "date", "sed", "tr", "cut"):
            p = binned / tool
            p.write_text('#!/bin/sh\nexec busybox %s "$@"\n' % tool)
            p.chmod(0o755)
    binned = work / "bin"
    binned.mkdir(exist_ok=True)
    # The settings page writes firewall config through the real
    # fwlive-logging, so it needs a uci and a firewall init to write to.
    (work / "firewall").write_text(FIREWALL)
    (binned / "uci").write_text(UCI_STUB)
    (binned / "uci").chmod(0o755)
    (binned / "firewall-init").write_text("#!/bin/sh\nexit 0\n")
    (binned / "firewall-init").chmod(0o755)

    print("workdir %s" % work, flush=True)
    spools = Spools(work)
    n = spools.backfill(args.minutes)
    print("  %d synthetic events over the last %d minutes" % (n, args.minutes), flush=True)

    formats = {"time_format": args.time_format, "date_format": args.date_format,
               "poll_interval": "2"}

    if not args.screenshots:
        serve(work, env_path, spools, args.port, formats, args.dark, args.live)
        if args.work:
            print("kept %s" % work)
        else:
            shutil.rmtree(work, ignore_errors=True)
        return

    # the third one is the query language: two terms, one of them an exclusion,
    # so the chips under the bar are in the image the README points at
    TERMS = '"drop wan in" -192.0.2.44'
    shots = [
        ("overview", [200, 0, 0, "", "", "", ""], {}),
        ("denied", [200, 0, 0, "drop,reject", "", "", ""],
         dict(filters={"verdict": ["drop", "reject"], "dir": "", "proto": "", "search": ""})),
        ("filter", [200, 0, 0, "", "", "", TERMS],
         dict(filters={"verdict": ["accept", "drop", "reject", "unknown"],
                       "dir": "", "proto": "", "search": TERMS})),
    ]
    DOCS.mkdir(exist_ok=True)
    if args.dark:
        print("  note: writing dark images over the light ones the README uses")
    for name, q, page_args in shots:
        data = run_query(work, env_path, q)
        page = write_page(work, name, data, formats=formats, dark=args.dark, **page_args)
        shoot(work, page, DOCS / ("live-%s.png" % name))

    counts = run_query(work, env_path, [1, 0, 0, "", "", "", ""])
    fw = run_logging(work, env_path, ["--list"])
    st = status_for(counts)
    # derived rather than baked, so the status rows and the panel below them
    # cannot disagree in the image
    blind = [r for r in fw.get("rules", [])
             if r.get("denies") and r.get("enabled") and not r.get("log")]
    st["status"]["unlogged denies"] = (
        "%d rules refuse traffic without logging it: %s"
        % (len(blind), ", ".join(r["name"] for r in blind)) if blind
        else "none, every rule that refuses traffic also logs it")
    st["status"]["logged rules"] = "%d with option log set" % sum(
        1 for r in fw.get("rules", []) if r.get("log"))
    page = write_settings_page(work, dark=args.dark, fixture={"status": st, "logging": fw})
    # taller: the firewall panel is at the bottom of a long form
    shoot(work, page, DOCS / "settings.png", height=2600)

    if args.work:
        print("kept %s" % work)
    else:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
