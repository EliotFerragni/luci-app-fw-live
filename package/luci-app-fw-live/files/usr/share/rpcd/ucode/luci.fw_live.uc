// rpcd backend for luci-app-fw-live.
// The filtering itself lives in /usr/bin/fwlive-query, which walks the buffer
// far faster than doing the same work here. Keep this file small and boring:
// it is one of the two things that cannot be tested off a router.

'use strict';

const fs = require('fs');

const QUERY = '/usr/bin/fwlive-query';
const STATUS = '/usr/bin/fwlive-status';
const LOGGING = '/usr/bin/fwlive-logging';

function run(cmd) {
	let p = fs.popen(cmd, 'r');
	if (!p)
		return '';
	let out = p.read('all') || '';
	p.close();
	return out;
}

function num(v, def, min, max) {
	let n = +v;
	if (!(n >= min) || !(n <= max))
		return def;
	return int(n);
}

function events(req) {
	let args = req.args || {};
	let limit = num(args.limit, 200, 1, 1000);
	// Per source high water marks the view already holds. 0 means "the most
	// recent limit events", which is what a filter change resets them to.
	let after_log = num(args.after_log, 0, 0, 1e15);
	let after_ct = num(args.after_ct, 0, 0, 1e15);

	// Everything below reaches a shell command line, so it is cut down to the
	// characters the field can actually hold, then length capped.
	let verdict = replace('' + (args.verdict || ''), /[^a-z,]/g, '');
	let proto = lc(replace('' + (args.proto || ''), /[^0-9A-Za-z]/g, ''));
	let dir = lc(replace('' + (args.dir || ''), /[^A-Za-z]/g, ''));
	let search = replace('' + (args.search || ''), /[^0-9A-Za-z.:_\/ -]/g, '');

	if (length(verdict) > 32)
		verdict = '';
	if (length(proto) > 12)
		proto = '';
	if (length(dir) > 8)
		dir = '';
	if (length(search) > 64)
		search = substr(search, 0, 64);

	let out = run(`${QUERY} ${limit} ${after_log} ${after_ct} '${verdict}' '${proto}' '${dir}' '${search}' 2>/dev/null`);
	let data = null;

	try { data = json(out); } catch (e) { data = null; }

	if (type(data) != 'object')
		return { error: 'No events yet. Check Settings for whether the capture service is running.' };

	return data;
}

// The firewall's zones and rules with their logging state, so the settings
// page can offer a checkbox instead of a command to paste.
function logging() {
	let out = run(`${LOGGING} --list 2>/dev/null`);
	let data = null;

	try { data = json(out); } catch (e) { data = null; }

	if (type(data) != 'object')
		return { error: 'Could not read the firewall configuration.' };

	return data;
}

// The only call in this package that changes anything outside its own config,
// and all it can change is option log, which decides whether a line is written
// and never whether traffic passes. Arguments are a comma separated list of
// <section>=0 or <section>=1; anything that is not exactly that is dropped
// here, so only a section identifier and a single digit reach a command line.
// fwlive-logging checks the section really is a zone or a rule before writing.
function set_logging(req) {
	let args = req.args || {};
	let parts = split('' + (args.set || ''), ',');
	let cmd = '';
	let n = 0;

	for (let p in parts) {
		p = trim(p);
		if (!match(p, /^[A-Za-z0-9_@[\]-]{1,64}=[01]$/))
			continue;
		n = n + 1;
		if (n > 64)
			break;
		cmd += ` '${p}'`;
	}

	if (n == 0)
		return { error: 'Nothing valid to change.' };

	let out = run(`${LOGGING} --set${cmd} 2>/dev/null`);
	let data = null;

	try { data = json(out); } catch (e) { data = null; }

	if (type(data) != 'object')
		return { error: 'The change could not be applied.' };

	return data;
}

function status() {
	let out = run(`${STATUS} 2>&1`);
	let info = {};

	for (let line in split(out, '\n')) {
		let i = index(line, ':');
		if (i > 0)
			info[trim(substr(line, 0, i))] = trim(substr(line, i + 1));
	}

	return { status: info, raw: out };
}

return {
	luci_fw_live: {
		events: {
			args: { limit: 200, after_log: 0, after_ct: 0, verdict: '', proto: '', dir: '', search: '' },
			call: events
		},
		status: {
			args: {},
			call: status
		},
		logging: {
			args: {},
			call: logging
		},
		set_logging: {
			args: { set: '' },
			call: set_logging
		}
	}
};
