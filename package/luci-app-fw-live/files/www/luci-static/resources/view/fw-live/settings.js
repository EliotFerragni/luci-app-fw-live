'use strict';
'require view';
'require form';
'require rpc';
'require ui';

const callStatus = rpc.declare({
	object: 'luci_fw_live',
	method: 'status'
});

const callLogging = rpc.declare({
	object: 'luci_fw_live',
	method: 'logging'
});

const callSetLogging = rpc.declare({
	object: 'luci_fw_live',
	method: 'set_logging',
	params: [ 'set' ]
});

function esc(x) {
	return String(x).replace(/[&<>"']/g, function(c) {
		return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
	});
}

// The one panel in this package that changes something outside its own
// config. It writes option log and nothing else: that option decides whether
// a line is written, never whether traffic passes, so no setting here can
// cost you access to the router. Everything else about the firewall stays
// exactly where you left it.
function loggingPanel(initial) {
	const panel = E('div', { 'class': 'cbi-section' });
	let data = initial;
	let wanted = {};
	let denyOnly = true;

	function reset() {
		wanted = {};
		for (let z of (data && data.zones) || [])
			wanted[z.sect] = !!z.log;
		for (let r of (data && data.rules) || [])
			wanted[r.sect] = !!r.log;
	}

	function dirty() {
		const out = [];
		for (let z of (data && data.zones) || [])
			if (wanted[z.sect] !== !!z.log) out.push(z.sect + '=' + (wanted[z.sect] ? 1 : 0));
		for (let r of (data && data.rules) || [])
			if (wanted[r.sect] !== !!r.log) out.push(r.sect + '=' + (wanted[r.sect] ? 1 : 0));
		return out;
	}

	function box(sect, onchange) {
		const b = E('input', { type: 'checkbox', change: onchange });
		// A property, not an attribute: E() would write checked="false", which
		// still checks the box.
		b.checked = !!wanted[sect];
		return b;
	}

	function row(sect, label, note, warn) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', style: 'width:1px' }, box(sect, function(ev) {
				wanted[sect] = ev.target.checked;
				refreshButtons();
			})),
			E('td', { 'class': 'td' }, [
				E('span', {}, label),
				note ? E('div', { style: 'opacity:0.65;font-size:12px' }, note) : '',
				warn ? E('div', { style: 'font-size:12px', 'class': 'fwl-warn' }, warn) : ''
			])
		]);
	}

	let applyBtn, resetBtn, statusLine;

	function refreshButtons() {
		const n = dirty().length;
		applyBtn.disabled = (n === 0);
		resetBtn.disabled = (n === 0);
		applyBtn.textContent = n ? _('Apply') + ' (' + n + ')' : _('Apply');
	}

	function apply() {
		const changes = dirty();
		if (!changes.length)
			return;
		applyBtn.disabled = true;
		statusLine.textContent = _('Applying and reloading the firewall...');
		callSetLogging(changes.join(',')).then(function(r) {
			if (!r || r.error) {
				ui.addNotification(null, E('p', (r && r.error) || _('The change could not be applied.')), 'error');
				statusLine.textContent = '';
				refreshButtons();
				return;
			}
			for (let e of r.errors || [])
				ui.addNotification(null, E('p', e), 'warning');
			if (r.staged)
				ui.addNotification(null, E('p', _('There were already unsaved firewall changes; ' +
					'committing this applied those too.')), 'warning');
			statusLine.textContent = '';
			ui.addNotification(null, E('p', _('Firewall logging updated') + ' (' + (r.changed || 0) + ').'), 'info');
			return callLogging().then(function(fresh) {
				if (fresh && !fresh.error) data = fresh;
				reset();
				repaint();
			});
		}).catch(function(e) {
			ui.addNotification(null, E('p', '' + e), 'error');
			statusLine.textContent = '';
			refreshButtons();
		});
	}

	function repaint() {
		panel.innerHTML = '';

		if (!data || data.error) {
			panel.appendChild(E('h3', {}, _('Firewall logging')));
			panel.appendChild(E('p', {}, (data && data.error) ||
				_('The firewall configuration could not be read.')));
			return;
		}

		const rules = (data.rules || []).filter(function(r) { return !denyOnly || r.denies || r.log; });
		const blind = (data.rules || []).filter(function(r) { return r.denies && r.enabled && !r.log; }).length;

		applyBtn = E('button', { 'class': 'cbi-button cbi-button-apply', click: apply }, _('Apply'));
		resetBtn = E('button', { 'class': 'cbi-button', click: function() { reset(); repaint(); } }, _('Revert'));
		statusLine = E('span', { style: 'margin-left:10px;font-size:13px;opacity:0.8' }, '');

		panel.appendChild(E('h3', {}, _('Firewall logging')));
		panel.appendChild(E('p', { 'class': 'cbi-section-descr' },
			_('Nothing denied reaches this page unless the firewall logs it. These boxes set ' +
			  'option log on a zone or a rule and nothing else: that option decides whether a ' +
			  'line is written, never whether traffic passes, so nothing here can lock you out. ' +
			  'Applying reloads the firewall.')));

		panel.appendChild(E('h4', {}, _('Zones')));
		panel.appendChild(E('p', { 'class': 'cbi-section-descr' },
			_('A zone logs the packets its own policy refuses. It does not log a packet that one ' +
			  'of your rules refused first, because that rule decided it.')));
		panel.appendChild(E('div', { 'class': 'table' },
			(data.zones || []).map(function(z) {
				return row(z.sect, z.name, z.sect === z.name ? '' : z.sect, '');
			})));

		panel.appendChild(E('h4', {}, _('Rules')));
		panel.appendChild(E('p', { 'class': 'cbi-section-descr' }, blind
			? blind + ' ' + _('of these refuse traffic without logging it, so those refusals ' +
			                  'are recorded nowhere at all.')
			: _('Every rule that refuses traffic also logs it.')));
		panel.appendChild(E('div', { 'class': 'table' },
			rules.length ? rules.map(function(r) {
				const note = (r.target || '') + (r.enabled === false ? ', ' + _('disabled') : '');
				return row(r.sect, r.name, note,
					(r.denies && r.enabled && !r.log) ? _('refuses traffic unseen') : '');
			}) : [ E('tr', { 'class': 'tr' }, E('td', { 'class': 'td' },
				E('em', {}, _('No rules to show.')))) ]));

		panel.appendChild(E('div', { style: 'margin-top:8px' }, [
			E('label', { style: 'font-size:13px' }, [
				(function() {
					const b = E('input', { type: 'checkbox', change: function(ev) {
						denyOnly = ev.target.checked;
						repaint();
					} });
					b.checked = denyOnly;
					return b;
				})(),
				' ' + _('only show rules that refuse traffic')
			])
		]));

		panel.appendChild(E('div', { style: 'margin-top:12px;display:flex;align-items:center;gap:8px' },
			[ applyBtn, resetBtn, statusLine ]));

		refreshButtons();
	}

	reset();
	repaint();
	return panel;
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus().catch(function() { return null; }),
			callLogging().catch(function(e) { return { error: '' + e }; })
		]);
	},

	render: function(res) {
		const st = (res && res[0] && res[0].status) || {};
		const fw = res && res[1];
		let m, s, o;

		m = new form.Map('fw-live', _('Firewall Live'),
			_('Settings for the capture service behind Status → Firewall Live. ' +
			  'It reads the firewall\'s own log and the conntrack event stream; it adds no ' +
			  'firewall rules and inspects no packets, so flow offloading is untouched.'));

		s = m.section(form.NamedSection, 'main', 'fw_live', _('Current state'));
		s.anonymous = true;
		s.addremove = false;

		// Option names become DOM ids, so they cannot carry the spaces some
		// of the status keys have.
		function info(id, key, label) {
			o = s.option(form.DummyValue, '_' + id, label);
			o.cfgvalue = function() { return st[key] || _('unknown'); };
		}

		info('service', 'service', _('Capture service'));
		info('ct', 'conntrack events', _('Accepted connections'));
		info('fwlog', 'firewall logging', _('Denied packets'));
		info('rules', 'logged rules', _('Named rules'));
		info('blind', 'unlogged denies', _('Rules refusing traffic unseen'));
		info('buffered', 'buffered', _('Buffered'));
		info('oldest', 'oldest event', _('Oldest event'));
		info('discarded', 'discarded', _('Discarded'));
		info('merged', 'merge rules', _('Rule names joined to verdicts'));
		info('prefixes', 'local prefixes', _('Local prefixes'));

		if (st['conntrack fix']) {
			o = s.option(form.DummyValue, '_ctfix', _('Turn on conntrack events'));
			o.rawhtml = true;
			o.cfgvalue = function() {
				return '<pre style="white-space:pre-wrap">' +
				       st['conntrack fix'].replace(/[&<>]/g, function(ch) {
					       return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[ch];
				       }) + '</pre>';
			};
		}

		o = s.option(form.Button, '_raw', _('Full diagnostics'));
		o.inputtitle = _('Show');
		o.inputstyle = 'apply';
		o.onclick = function() {
			ui.showModal(_('fwlive-status'), [
				E('pre', { style: 'white-space:pre-wrap' }, (res && res[0] && res[0].raw) || ''),
				E('div', { 'class': 'right' },
					E('button', { 'class': 'cbi-button', click: ui.hideModal }, _('Close')))
			]);
		};

		s = m.section(form.NamedSection, 'main', 'fw_live', _('Capture'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'),
			_('Master switch. With this off the service stops and the page has nothing to show.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'accepts', _('Capture accepted connections'),
			_('From the conntrack event stream. A connection only gets a conntrack entry once ' +
			  'it has cleared the ruleset, which makes this a complete record of what got ' +
			  'through, at the cost of not knowing which rule allowed it.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'denies', _('Capture denied packets'),
			_('From the firewall\'s kernel log. A drop leaves nothing behind unless it is ' +
			  'logged, so this needs option log \'1\' on at least one firewall zone.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'merge_rules', _('Join a rule to its verdict'),
			_('A packet can be logged twice: once by the rule it matched, whose prefix is only ' +
			  'a name, and again by the chain that refused it, whose prefix carries the verdict. ' +
			  'Neither line alone says both things. With this on the two become one row, with ' +
			  'the rule name and the real verdict, and you get one row rather than two.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'ignore_unknown', _('Ignore rules that do not state a verdict'),
			_('A rule logged with option log writes only its own name to the log, which says ' +
			  'nothing about what became of the packet, so those events show as Unknown. ' +
			  'Turn this on when the rule that logs is not the rule that decides, such as a ' +
			  'MARK rule used for policy routing: its events are then duplicates of rows you ' +
			  'already have. Leave it off if a rule both logs and refuses traffic, because ' +
			  'its events are the only record of that traffic.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Flag, 'ignore_local', _('Ignore router-local traffic'),
			_('Leave out events where both ends are on a network this router owns, which is ' +
			  'mostly devices talking to the router itself.'));
		o.default = '0';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'main', 'fw_live', _('Buffer'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'buffer_size', _('Events kept'),
			_('Per feed, in RAM only. Nothing survives a reboot: this is a live view, not a ' +
			  'history. Roughly 120 bytes per event.'));
		o.datatype = 'range(100,100000)';
		o.placeholder = '5000';
		o.value('1000', _('1000 events'));
		o.value('5000', _('5000 events'));
		o.value('20000', _('20000 events'));

		o = s.option(form.Value, 'max_rate', _('Rate limit'),
			_('Events per second per feed before the excess is dropped and counted. A log rule ' +
			  'matching far more than it should must not be able to wedge the router.'));
		o.datatype = 'range(0,100000)';
		o.placeholder = '200';
		o.value('0', _('no limit'));
		o.value('200', _('200 per second'));
		o.value('1000', _('1000 per second'));

		s = m.section(form.NamedSection, 'main', 'fw_live', _('Display'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'poll_interval', _('Refresh every'),
			_('Seconds between the page asking for new events. Each poll only carries what is ' +
			  'new since the last one.'));
		o.datatype = 'range(1,60)';
		o.placeholder = '2';
		o.value('1', _('1 second'));
		o.value('2', _('2 seconds'));
		o.value('5', _('5 seconds'));
		o.value('10', _('10 seconds'));

		o = s.option(form.ListValue, 'time_format', _('Clock'),
			_('How the page prints times. Automatic follows the browser the page is open in.'));
		o.value('auto', _('Automatic'));
		o.value('24', _('24 hour (14:05)'));
		o.value('12', _('12 hour (2:05 PM)'));
		o.default = 'auto';

		o = s.option(form.ListValue, 'date_format', _('Date order'),
			_('How the page prints dates. Automatic follows the browser the page is open in.'));
		o.value('auto', _('Automatic'));
		o.value('dmy', _('Day first (31/12)'));
		o.value('mdy', _('Month first (12/31)'));
		o.default = 'auto';

		// The firewall panel is not part of the fw-live map: it writes a
		// different config through its own ubus call, with its own Apply, so
		// that Save & Apply on this page never touches the firewall.
		return m.render().then(function(node) {
			node.appendChild(loggingPanel(fw));
			return node;
		});
	}
});
