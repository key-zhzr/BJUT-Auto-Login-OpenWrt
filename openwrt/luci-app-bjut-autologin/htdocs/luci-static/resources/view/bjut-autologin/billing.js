'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

const status = rpc.declare({ object: 'bjut-autologin', method: 'status', expect: {} });
const accounts = rpc.declare({ object: 'bjut-autologin', method: 'accounts', expect: {} });
const begin = rpc.declare({ object: 'bjut-autologin', method: 'billing_start', params: ['uplink', 'account', 'owner'], expect: {} });
const result = rpc.declare({ object: 'bjut-autologin', method: 'billing_poll', params: ['ticket', 'owner'], expect: {} });
const captcha = rpc.declare({ object: 'bjut-autologin', method: 'billing_captcha', params: ['ticket', 'owner', 'code', 'refresh'], expect: {} });

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
	load: function() { return Promise.all([status(), accounts()]); },
	render: function(data) {
		let ticket = '', activeUplink = '', activeAccount = '', busy = false;
		const uplinks = data[0].uplinks || [];
		const uplink = E('select', { 'class': 'cbi-input-select' }, uplinks.map(function(item) {
			return E('option', { value: item.id }, [item.id, item.network, item.device, item.ipv4].filter(Boolean).join(' · '));
		}));
		const account = E('select', { 'class': 'cbi-input-select' }, (data[1].accounts || []).filter(function(item) { return item.hasPassword; }).map(function(item) {
			return E('option', { value: item.id }, item.user + (item.enabled ? '' : _('（手动）')));
		}));
		const message = E('p', {}, _('选择上游与计费账号后查询。'));
		const details = E('div');
		const submit = E('button', { 'class': 'btn cbi-button-action', type: 'button', click: refresh }, _('刷新查询'));
		const selectors = E('div', { style: 'display:flex;gap:12px;flex-wrap:wrap;align-items:end;margin-bottom:16px' }, [
			E('label', { style: 'flex:1;min-width:180px' }, [E('div', {}, _('上游')), uplink]),
			E('label', { style: 'flex:1;min-width:180px' }, [E('div', {}, _('计费账号')), account]), submit
		]);
		function setMessage(text) { message.textContent = text; }
		async function refresh() {
			if (busy || !uplink.value || !account.value) return;
			activeUplink = uplink.value; activeAccount = account.value;
			details.replaceChildren(); setMessage(_('正在准备查询…'));
			busy = true; submit.disabled = true;
			try {
				const response = await begin(activeUplink, activeAccount, L.env.sessionid);
				if (!response.ticket) throw new Error(response.message || _('无法开始查询'));
				ticket = response.ticket;
			} catch (error) { setMessage(String(error.message || error)); busy = false; submit.disabled = false; }
		}
		function changed() {
			ticket = ''; busy = false; submit.disabled = false;
			details.replaceChildren(); setMessage(_('选择已变更，请刷新查询。'));
		}
		uplink.addEventListener('change', changed); account.addEventListener('change', changed);
		function row(label, value) { return E('div', { style: 'padding:8px 0;overflow-wrap:anywhere' }, [E('strong', {}, label + '：'), String(value || '--')]); }
		poll.add(async function() {
			if (!ticket || !busy) return;
			const current = ticket;
			try {
				const response = await result(current, L.env.sessionid);
				if (ticket !== current) return;
				const item = response.result || response;
				setMessage(item.message + (item.state === 'loading' ? ' · ' + (item.percent || 0) + '%' : ''));
				if (item.state === 'loading') {
					if (item.account) details.replaceChildren(row(_('账号'), item.account), row(_('余额'), item.balance + ' 元'), row(_('剩余流量'), item.remainingFlow + ' MB'), row(_('状态'), item.accountStatus), row(_('套餐'), item.package));
					return;
				}
				busy = false; submit.disabled = false;
				if (item.state === 'captcha') {
					const input = E('input', { type: 'text', maxlength: 12, autocomplete: 'off', placeholder: _('验证码'), 'class': 'cbi-input-text' });
					const image = E('img', { src: item.image, alt: _('计费系统验证码'), style: 'max-width:240px;display:block;margin:12px 0' });
					async function answer(refreshImage) {
						if (busy) return;
						busy = true; submit.disabled = true;
						try {
							const next = await captcha(current, L.env.sessionid, input.value.trim(), refreshImage);
							if (next.state === 'error') throw new Error(next.message);
							details.replaceChildren(); setMessage(next.message);
						} catch (error) { setMessage(String(error.message || error)); busy = false; submit.disabled = false; }
					}
					details.replaceChildren(E('div', {}, [image, input, E('div', { style: 'display:flex;gap:12px;margin-top:12px' }, [
						E('button', { type: 'button', 'class': 'btn', click: function() { answer(true); } }, _('换一张')),
						E('button', { type: 'button', 'class': 'btn cbi-button-action', click: function() { answer(false); } }, _('继续'))
					])]));
				} else if (item.state === 'ready') {
					const cards = [row(_('账号'), item.account), row(_('上游'), activeUplink), row(_('余额'), item.balance ? item.balance + ' 元' : ''),
						row(_('剩余流量'), item.remainingFlow ? item.remainingFlow + ' MB' : ''), row(_('状态'), item.accountStatus), row(_('套餐'), item.package)];
					cards.push(E('h3', {}, _('在线设备')));
					(response.sessions || []).forEach(function(session) {
						cards.push(E('div', { 'class': 'cbi-section' }, [row('IPv4', session.ip), row('IPv6', session.ipv6), row('MAC', session.mac), row(_('在线时长'), session.useTime ? Math.round(Number(session.useTime) / 60) + ' ' + _('分钟') : '')]));
					});
					if (!(response.sessions || []).length) cards.push(E('p', {}, response.sessionsAvailable ? _('暂无在线设备。') : _('在线设备暂时无法查询，请稍后刷新。')));
					details.replaceChildren.apply(details, cards);
				}
			} catch (error) { if (ticket === current) { setMessage(_('查询未完成：') + String(error.message || error)); busy = false; submit.disabled = false; } }
		}, 2);
		return E('div', { 'class': 'cbi-map' }, [E('h2', {}, _('计费系统')), E('p', {}, _('通过指定上游查询账号余额、流量与在线设备。')), selectors, message, details]);
	}
});
