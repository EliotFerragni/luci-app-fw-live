'use strict';
'require view';
'require rpc';
'require poll';
'require uci';
'require network';

const callEvents = rpc.declare({
	object: 'luci_fw_live',
	method: 'events',
	params: [ 'limit', 'after_log', 'after_ct', 'verdict', 'proto', 'dir', 'search' ]
});

const callStatus = rpc.declare({
	object: 'luci_fw_live',
	method: 'status'
});

// How many events one request may carry, and how many rows the table keeps.
// The buffer on the router is far larger; this is what the DOM can hold
// without the page getting slow after an hour of tailing.
const LIMIT = 200;
const MAX_ROWS = 500;

// Status runs uci loops on the router, so it is refreshed on its own slower
// cadence rather than on every tick of the tail.
const STATUS_EVERY = 10;

// unknown is a packet logged by a rule whose prefix does not say what became
// of it, which is every rule logged through option log. It is not a failure
// to parse, so it gets a neutral chip rather than being folded into drop.
const VERDICTS = [ 'accept', 'drop', 'reject', 'unknown' ];

// Stamped into the saved filter state, see loadFilters().
const FILTER_VERSION = 1;

let state = {
	verdict: { accept: true, drop: true, reject: true },
	dir: '',
	proto: '',
	search: '',
	paused: false,
	cursor: { log: 0, ct: 0 },
	data: null,
	status: null
};

let hints = null;
let ticks = 0;

let FORMATS = { time: 'auto', date: 'auto' };

function loadFormats() {
	let t, d;
	try {
		t = uci.get('fw-live', 'main', 'time_format');
		d = uci.get('fw-live', 'main', 'date_format');
	}
	catch (e) {}
	FORMATS = {
		time: (t === '12' || t === '24') ? t : 'auto',
		date: (d === 'dmy' || d === 'mdy') ? d : 'auto'
	};
}

function pollInterval() {
	let v;
	try { v = parseInt(uci.get('fw-live', 'main', 'poll_interval'), 10); } catch (e) {}
	if (!(v >= 1) || !(v <= 60)) v = 2;
	return v;
}

// Blocked site data and private windows make localStorage throw rather than
// come back empty, so every access goes through these two.
function stored(key) {
	try { return window.localStorage.getItem(key); } catch (e) { return null; }
}

function store(key, value) {
	try { window.localStorage.setItem(key, value); } catch (e) {}
}

function loadFilters() {
	const raw = stored('fw-live.filters');
	if (raw) {
		try {
			const s = JSON.parse(raw) || {};
			// A saved verdict list is a list of what to show, so one written
			// before a verdict existed would silently hide it, and there is no
			// way to tell that apart from the user having unticked it. The
			// stamp settles it: state from an older page is discarded rather
			// than half applied. Bump it whenever a filter gains a value.
			if (s.v !== FILTER_VERSION) throw 0;
			if (Array.isArray(s.verdict)) {
				VERDICTS.forEach(function(v) { state.verdict[v] = false; });
				for (let v of s.verdict)
					if (state.verdict[v] !== undefined) state.verdict[v] = true;
			}
			if (typeof s.dir === 'string') state.dir = s.dir;
			if (typeof s.proto === 'string') state.proto = s.proto;
			if (typeof s.search === 'string') state.search = s.search;
		} catch (e) {}
	}
	state.paused = (stored('fw-live.paused') === '1');
}

function saveFilters() {
	store('fw-live.filters', JSON.stringify({
		v: FILTER_VERSION,
		verdict: VERDICTS.filter(function(v) { return state.verdict[v]; }),
		dir: state.dir,
		proto: state.proto,
		search: state.search
	}));
}

// All three ticked is the same question as no filter at all, and asking for
// nothing is a filter that legitimately matches nothing.
function verdictParam() {
	const on = VERDICTS.filter(function(v) { return state.verdict[v]; });
	if (on.length === VERDICTS.length) return '';
	if (on.length === 0) return 'none';
	return on.join(',');
}

function filtersActive() {
	return verdictParam() !== '' || state.dir !== '' || state.proto !== '' || state.search !== '';
}

function clockOpts(opts) {
	if (FORMATS.time === '12') return Object.assign({ hour12: true }, opts);
	if (FORMATS.time === '24') return Object.assign({ hourCycle: 'h23' }, opts);
	return opts;
}

function fmtClock(ts) {
	const d = new Date(ts * 1000);
	return d.toLocaleTimeString([], clockOpts({ hour: '2-digit', minute: '2-digit', second: '2-digit' }));
}

function fmtDayMonth(ts) {
	const d = new Date(ts * 1000);
	const dd = ('0' + d.getDate()).slice(-2);
	const mm = ('0' + (d.getMonth() + 1)).slice(-2);
	if (FORMATS.date === 'dmy') return dd + '/' + mm;
	if (FORMATS.date === 'mdy') return mm + '/' + dd;
	return d.toLocaleDateString([], { day: '2-digit', month: '2-digit' });
}

// Resolved in the browser from LuCI's own host hints, so the backend stays
// thin and the router does no lookups per event.
function hostname(addr) {
	if (!hints || !addr || addr === '-') return null;
	try {
		const n = (addr.indexOf(':') >= 0)
			? (hints.getHostnameByIP6Addr ? hints.getHostnameByIP6Addr(addr) : null)
			: (hints.getHostnameByIPAddr ? hints.getHostnameByIPAddr(addr) : null);
		return (n && n !== addr) ? n : null;
	}
	catch (e) { return null; }
}

const DIR_LABEL = {
	'in': _('Inbound'),
	'out': _('Outbound'),
	'local': _('Local'),
	'-': _('Unknown')
};

const VERDICT_LABEL = {
	accept: _('Accepted'),
	drop: _('Dropped'),
	reject: _('Rejected'),
	unknown: _('Unknown')
};

const VERDICT_HINT = {
	unknown: _('This packet matched a rule that logs under its own name, and the name is all ' +
	          'the firewall writes to the log. No accepted connection was recorded for it ' +
	          'either, so it was most likely refused, but nothing here proves that.')
};

const CSS = '' +
'.fwl-bar { display:flex; flex-wrap:wrap; align-items:center; gap:8px 14px }' +
'.fwl-chip { display:inline-block; padding:1px 8px; border-radius:10px; font-size:12px;' +
'  font-weight:600; line-height:18px; white-space:nowrap; border:1px solid transparent }' +
'.fwl-accept { background:rgba(78,158,106,0.16); color:#2f7a4d; border-color:rgba(78,158,106,0.45) }' +
'.fwl-drop { background:rgba(194,80,79,0.18); color:#b03a39; border-color:rgba(194,80,79,0.5) }' +
'.fwl-reject { background:rgba(217,128,50,0.18); color:#a9651f; border-color:rgba(217,128,50,0.5) }' +
'.fwl-unknown { background:rgba(130,140,150,0.16); color:#5c666f; border-color:rgba(130,140,150,0.5) }' +
'.fwl-denied .fwl-time { box-shadow:inset 3px 0 0 rgba(194,80,79,0.75) }' +
'.fwl-time { padding-left:10px !important; white-space:nowrap; font-variant-numeric:tabular-nums }' +
'.fwl-sub { opacity:0.7; font-size:12px }' +
'.fwl-toggle { cursor:pointer; user-select:none; padding:2px 10px; border-radius:12px;' +
'  border:1px solid currentColor; font-size:12px; line-height:18px; opacity:0.45 }' +
'.fwl-toggle.on { opacity:1 }' +
'.fwl-paused { background:rgba(217,128,50,0.16) }' +
'.fwl-new td, .fwl-new .td { animation:fwl-flash 1.2s ease-out }' +
'@keyframes fwl-flash { from { background:rgba(120,160,220,0.28) } to { background:transparent } }' +
'@media (prefers-color-scheme: dark) {' +
'  .fwl-accept { color:#7fce9c } .fwl-drop { color:#f08a89 } .fwl-reject { color:#e7a760 }' +
'  .fwl-unknown { color:#aab3bc } }';

return view.extend({
	load: function() {
		loadFilters();
		return Promise.all([
			callStatus().catch(function() { return null; }),
			callEvents(LIMIT, 0, 0, verdictParam(), state.proto, state.dir, state.search)
				.catch(function(e) { return { error: '' + e }; }),
			uci.load('fw-live').catch(function() {}),
			network.getHostHints().catch(function() { return null; })
		]);
	},

	render: function(res) {
		state.status = res[0];
		state.data = res[1];
		hints = res[3];
		loadFormats();

		const tableNode = E('div', { 'class': 'table' });
		const headRow = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th fwl-time' }, _('Time')),
			E('th', { 'class': 'th' }, _('Verdict')),
			E('th', { 'class': 'th' }, _('Direction')),
			E('th', { 'class': 'th' }, _('Protocol')),
			E('th', { 'class': 'th' }, _('Source')),
			E('th', { 'class': 'th' }, _('Destination')),
			E('th', { 'class': 'th' }, _('Rule'))
		]);
		tableNode.appendChild(headRow);

		const emptyNode = E('div', { style: 'padding:10px 2px;opacity:0.7' });
		const summaryNode = E('div', { style: 'font-size:13px;margin-top:8px' });
		const statusNode = E('div', { style: 'font-size:13px;opacity:0.75;margin-top:4px' });
		const errorNode = E('div', { 'class': 'alert-message warning', style: 'display:none' });

		const searchInput = E('input', {
			type: 'text',
			'class': 'cbi-input-text',
			placeholder: _('address, port or rule'),
			style: 'min-width:200px',
			value: state.search
		});

		const dirSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: '' }, _('Any direction')),
			E('option', { value: 'in' }, DIR_LABEL['in']),
			E('option', { value: 'out' }, DIR_LABEL['out']),
			E('option', { value: 'local' }, DIR_LABEL['local'])
		]);

		const protoSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: '' }, _('Any protocol')),
			E('option', { value: 'tcp' }, 'TCP'),
			E('option', { value: 'udp' }, 'UDP'),
			E('option', { value: 'icmp' }, 'ICMP'),
			E('option', { value: 'icmpv6' }, 'ICMPv6')
		]);

		const pauseBtn = E('button', { 'class': 'cbi-button' }, '');

		const verdictToggles = {};
		const verdictBox = E('span', { style: 'display:flex;gap:6px' },
			VERDICTS.map(function(v) {
				const t = E('span', {
					'class': 'fwl-toggle fwl-' + v,
					title: _('Show or hide these'),
					click: function() { toggleVerdict(v); }
				}, VERDICT_LABEL[v]);
				verdictToggles[v] = t;
				return t;
			}));

		const clearLink = E('a', {
			href: '#',
			click: function(ev) { ev.preventDefault(); clearFilters(); }
		}, _('clear filters'));

		function rowCount() {
			return tableNode.childNodes.length - 1;
		}

		function clearRows() {
			while (tableNode.childNodes.length > 1)
				tableNode.removeChild(tableNode.lastChild);
		}

		function link(text, title, fn) {
			return E('a', {
				href: '#',
				title: title,
				click: function(ev) { ev.preventDefault(); fn(); }
			}, text);
		}

		function endpoint(addr, port) {
			const name = hostname(addr);
			const line = E('div', {}, [ link(addr, _('Filter on this address'),
				function() { setSearch(addr); }) ]);
			if (port && port !== '-') {
				line.appendChild(document.createTextNode(':'));
				line.appendChild(link(port, _('Filter on this port'),
					function() { setSearch(port); }));
			}
			if (!name)
				return line;
			return E('div', {}, [
				E('div', {}, link(name, _('Filter on this host'), function() { setSearch(addr); })),
				E('div', { 'class': 'fwl-sub' }, line)
			]);
		}

		function buildRow(e, fresh) {
			const denied = (e.verdict === 'drop' || e.verdict === 'reject');
			const cls = 'tr' + (denied ? ' fwl-denied' : '') + (fresh ? ' fwl-new' : '');
			const rule = (e.rule && e.rule !== '-') ? e.rule : '';
			const when = E('div', {}, fmtClock(e.ts));
			const extra = (e.extra && e.extra !== '-') ? e.extra : '';

			return E('tr', { 'class': cls, 'data-id': e.id }, [
				E('td', { 'class': 'td fwl-time', title: fmtDayMonth(e.ts) }, when),
				E('td', { 'class': 'td' },
					E('span', {
						'class': 'fwl-chip fwl-' + e.verdict,
						style: 'cursor:pointer',
						title: VERDICT_HINT[e.verdict] || _('Show only these'),
						click: function() { onlyVerdict(e.verdict); }
					}, VERDICT_LABEL[e.verdict] || e.verdict)),
				E('td', { 'class': 'td' }, [
					(e.dir === '-') ? E('span', { style: 'opacity:0.6' }, DIR_LABEL['-'])
						: link(DIR_LABEL[e.dir] || e.dir, _('Filter on this direction'),
							function() { setDir(e.dir); }),
					(e.iif && e.iif !== '-')
						? E('div', { 'class': 'fwl-sub' }, e.iif + (e.oif && e.oif !== '-' ? ' → ' + e.oif : ''))
						: ''
				]),
				E('td', { 'class': 'td' }, [
					E('div', {}, [
						link(e.proto.toUpperCase(), _('Filter on this protocol'),
							function() { setProto(e.proto); }),
						E('span', { 'class': 'fwl-sub' }, ' IPv' + e.fam)
					]),
					extra ? E('div', { 'class': 'fwl-sub' }, extra) : ''
				]),
				E('td', { 'class': 'td' }, endpoint(e.saddr, e.sport)),
				E('td', { 'class': 'td' }, endpoint(e.daddr, e.dport)),
				E('td', { 'class': 'td' }, rule
					? link(rule, _('Filter on this rule'), function() { setSearch(rule); })
					: E('span', { style: 'opacity:0.45' }, '\u00b7'))
			]);
		}

		function prepend(events, fresh) {
			// The response is newest first, so walking it backwards and
			// pushing each row to the top leaves the newest on top.
			for (let i = events.length - 1; i >= 0; i--)
				tableNode.insertBefore(buildRow(events[i], fresh), tableNode.childNodes[1] || null);
			while (rowCount() > MAX_ROWS)
				tableNode.removeChild(tableNode.lastChild);
		}

		function syncControls() {
			VERDICTS.forEach(function(v) {
				verdictToggles[v].className = 'fwl-toggle fwl-' + v + (state.verdict[v] ? ' on' : '');
			});
			if (state.dir && !Array.prototype.some.call(dirSel.options, function(o) { return o.value === state.dir; }))
				dirSel.appendChild(E('option', { value: state.dir }, state.dir));
			dirSel.value = state.dir;
			if (state.proto && !Array.prototype.some.call(protoSel.options, function(o) { return o.value === state.proto; }))
				protoSel.appendChild(E('option', { value: state.proto }, state.proto.toUpperCase()));
			protoSel.value = state.proto;
			if (searchInput.value !== state.search)
				searchInput.value = state.search;
			pauseBtn.textContent = state.paused ? _('Resume') : _('Pause');
			pauseBtn.className = 'cbi-button' + (state.paused ? ' cbi-button-negative' : ' cbi-button-action');
			clearLink.style.display = filtersActive() ? '' : 'none';
		}

		function paint() {
			const data = state.data;
			if (!data || data.error) {
				errorNode.style.display = '';
				errorNode.textContent = (data && data.error) || _('No data returned.');
				return;
			}
			errorNode.style.display = 'none';

			const c = data.counts || {};
			const bits = [
				(c.accept || 0) + ' ' + _('accepted'),
				(c.drop || 0) + ' ' + _('dropped'),
				(c.reject || 0) + ' ' + _('rejected')
			];
			if (c.unknown)
				bits.push(c.unknown + ' ' + _('unknown'));
			if (data.resolved)
				bits.push(data.resolved + ' ' + _('resolved from conntrack'));
			let line = _('In the buffer') + ': ' + bits.join(' · ');
			// Not "showing N of M": the row count is what this browser has
			// accumulated while tailing, and matched is what the router holds
			// right now. Once the buffer rolls, the first is legitimately
			// larger than the second, and comparing them reads as nonsense.
			if (filtersActive())
				line += '. ' + (data.matched || 0) + ' ' + _('match the filter');
			if (rowCount() >= MAX_ROWS)
				line += '. ' + _('The page keeps the newest') + ' ' + MAX_ROWS + ' ' + _('rows');
			if (state.paused)
				line += '. ' + _('Paused, the tail is frozen.');
			summaryNode.textContent = line;

			emptyNode.textContent = rowCount() ? '' :
				(filtersActive()
					? _('Nothing in the buffer matches this filter yet.')
					: _('No events captured yet. Check Settings if this stays empty.'));

			const st = (state.status && state.status.status) || {};
			const parts = [
				_('Service') + ': ' + (st['service'] || _('unknown')),
				_('accepts') + ': ' + (st['conntrack events'] || _('unknown')),
				_('denies') + ': ' + (st['firewall logging'] || _('unknown'))
			];
			// Worth saying on the page rather than only in Settings: these are
			// refusals happening now that nothing on the router records.
			const blind = st['unlogged denies'];
			if (blind && blind.indexOf('none') !== 0)
				parts.push(blind);
			if (data.dropped)
				parts.push(_('rate limit has discarded') + ' ' + data.dropped + ' ' + _('events'));
			statusNode.textContent = parts.join(' \u00b7 ');
		}

		function handle(data) {
			state.data = data;
			if (!data || data.error)
				return;

			const seq = data.seq || { log: 0, ct: 0 };
			// A lower sequence than we hold means the capture service was
			// restarted and the buffer started again from one, so the cursor
			// we were holding points past the end of a buffer that no longer
			// exists.
			if (seq.log < state.cursor.log || seq.ct < state.cursor.ct) {
				state.cursor = { log: 0, ct: 0 };
				clearRows();
				return refresh(false);
			}

			const fresh = (state.cursor.log > 0 || state.cursor.ct > 0);
			prepend(data.events || [], fresh);
			state.cursor = { log: seq.log || 0, ct: seq.ct || 0 };
			paint();
			return null;
		}

		function refresh(reset) {
			if (reset) {
				state.cursor = { log: 0, ct: 0 };
				clearRows();
			}
			return callEvents(LIMIT, state.cursor.log, state.cursor.ct,
				verdictParam(), state.proto, state.dir, state.search)
				.then(handle)
				.catch(function(e) { state.data = { error: '' + e }; paint(); });
		}

		function refilter() {
			saveFilters();
			syncControls();
			return refresh(true);
		}

		function toggleVerdict(v) {
			state.verdict[v] = !state.verdict[v];
			refilter();
		}

		function onlyVerdict(v) {
			const alone = VERDICTS.every(function(x) { return state.verdict[x] === (x === v); });
			VERDICTS.forEach(function(x) { state.verdict[x] = alone ? true : (x === v); });
			refilter();
		}

		function setDir(v) {
			state.dir = (state.dir === v) ? '' : v;
			refilter();
		}

		function setProto(v) {
			state.proto = (state.proto === v) ? '' : v;
			refilter();
		}

		function setSearch(v) {
			state.search = (state.search === v) ? '' : v;
			refilter();
		}

		function clearFilters() {
			VERDICTS.forEach(function(v) { state.verdict[v] = true; });
			state.dir = '';
			state.proto = '';
			state.search = '';
			refilter();
		}

		pauseBtn.addEventListener('click', function(ev) {
			ev.preventDefault();
			state.paused = !state.paused;
			store('fw-live.paused', state.paused ? '1' : '0');
			syncControls();
			paint();
			// Resuming keeps the cursors, so everything that happened while
			// the tail was frozen arrives in one go rather than being lost.
			if (!state.paused) refresh(false);
		});

		dirSel.addEventListener('change', function() { state.dir = dirSel.value; refilter(); });
		protoSel.addEventListener('change', function() { state.proto = protoSel.value; refilter(); });

		let typing = null;
		searchInput.addEventListener('input', function() {
			if (typing) window.clearTimeout(typing);
			typing = window.setTimeout(function() {
				state.search = searchInput.value;
				refilter();
			}, 400);
		});

		poll.add(function() {
			ticks++;
			const jobs = [];
			if (ticks % STATUS_EVERY === 0)
				jobs.push(callStatus().then(function(st) { state.status = st; }).catch(function() {}));
			if (!state.paused)
				jobs.push(refresh(false));
			else
				paint();
			return Promise.all(jobs);
		}, pollInterval());

		const body = E('div', { 'class': 'cbi-map' }, [
			E('style', {}, CSS),
			E('h2', {}, _('Firewall Live')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'fwl-bar' }, [
					pauseBtn,
					verdictBox,
					dirSel,
					protoSel,
					searchInput,
					clearLink
				]),
				E('p', { 'class': 'cbi-section-descr', style: 'margin:8px 0 0' },
					_('Connections the firewall accepted and packets it refused, as they happen. ' +
					  'Click any address, port, protocol, direction or rule to filter on it. ' +
					  'Accepted connections normally have no rule name: they come from the conntrack ' +
					  'event stream, which does not know which rule let them through. A row marked ' +
					  'Unknown matched a rule that logs under its own name, which says nothing about ' +
					  'what happened to the packet.')),
				summaryNode,
				statusNode,
				errorNode
			]),
			E('div', { 'class': 'cbi-section' }, [ tableNode, emptyNode ])
		]);

		syncControls();
		handle(state.data);
		paint();
		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
