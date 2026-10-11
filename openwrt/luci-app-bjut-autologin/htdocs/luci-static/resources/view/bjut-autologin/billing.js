'use strict';
'require view';
'require rpc';
'require poll';

const status = rpc.declare({ object: 'bjut-autologin', method: 'status', expect: {} });
const accounts = rpc.declare({ object: 'bjut-autologin', method: 'accounts', expect: {} });
const begin = rpc.declare({ object: 'bjut-autologin', method: 'billing_start', params: ['uplink', 'account', 'owner'], expect: {} });
const result = rpc.declare({ object: 'bjut-autologin', method: 'billing_poll', params: ['ticket', 'owner'], expect: {} });
const captcha = rpc.declare({ object: 'bjut-autologin', method: 'billing_captcha', params: ['ticket', 'owner', 'code', 'refresh'], expect: {} });

return view.extend({
	handleSave: null, handleSaveApply: null, handleReset: null,
	load: function() { return Promise.all([status(), accounts()]); },
	render: function(data) {
		let jobs = [], busy = false, pending = false;
		const uplinks = data[0].uplinks || [];
		const selectStyle = 'width:100%;min-height:42px';
		const uplink = E('select', { 'class': 'cbi-input-select', style: selectStyle }, [E('option', { value: 'all' }, _('所有上游（自动汇总）'))].concat(uplinks.map(function(item) {
			return E('option', { value: item.id }, [item.id, item.network, item.device, item.ipv4].filter(Boolean).join(' · '));
		})));
		const account = E('select', { 'class': 'cbi-input-select', style: selectStyle }, [E('option', { value: 'current' }, _('当前认证账号'))].concat((data[1].accounts || []).filter(function(item) { return item.hasPassword; }).map(function(item) {
			return E('option', { value: item.id }, item.user + (item.enabled ? '' : _('（手动）')));
		})));
		const message = E('p');
		const summary = E('div', { 'class': 'cbi-section', style: 'padding:16px;overflow-wrap:anywhere', hidden: true });
		const details = E('div');
		const submit = E('button', { 'class': 'btn cbi-button-action', type: 'button', style: 'min-height:42px', click: refresh }, _('刷新查询'));
		const selectors = E('div', { style: 'display:flex;gap:12px;flex-wrap:wrap;align-items:end;margin-bottom:16px' }, [
			E('label', { style: 'flex:1;min-width:180px;max-width:100%' }, [E('div', {}, _('上游')), uplink]),
			E('label', { style: 'flex:1;min-width:180px;max-width:100%' }, [E('div', {}, _('计费账号')), account]), submit
		]);
		function row(label, value) { return E('div', { style: 'padding:6px 0;overflow-wrap:anywhere' }, [E('strong', {}, label + '：'), String(value == null || value === '' ? '--' : value)]); }
		function updateSummary() {
			const unique = new Map();
			jobs.forEach(function(job) { if (job.item && job.item.account) unique.set(job.item.account, job.item); });
			const items = Array.from(unique.values());
			const balances = items.map(function(item) { return item.balance === '' || item.balance == null ? NaN : Number(item.balance); });
			const completed = jobs.filter(function(job) { return !job.running && job.started; }).length;
			busy = jobs.some(function(job) { return job.running || !job.started; }); submit.disabled = busy;
			message.textContent = (busy ? _('正在查询各条上游…') : _('查询已结束')) + ' ' + completed + ' / ' + jobs.length;
			summary.hidden = !items.length;
			summary.replaceChildren(E('h3', {}, _('账号汇总')), row(_('已查询账号'), items.length),
				row(_('余额合计'), balances.every(Number.isFinite) ? balances.reduce(function(a, b) { return a + b; }, 0).toFixed(2) + ' 元' : _('部分余额暂不可用')),
				E('p', {}, _('同一账号通过多个上游查询时只统计一次。')));
			if (!busy && pending) { pending = false; void refresh(); }
		}
		async function startJob(job) {
			job.started = true; job.running = true; job.content.textContent = _('正在准备查询…');
			try {
				const response = await begin(job.uplink, job.account, L.env.sessionid);
				if (!response.ticket) throw new Error(response.message || _('无法开始查询'));
				job.ticket = response.ticket;
			} catch (error) { job.running = false; job.content.textContent = String(error.message || error); }
			updateSummary(); pump();
		}
		function pump() {
			const free = 4 - jobs.filter(function(job) { return job.running; }).length;
			jobs.filter(function(job) { return !job.started; }).slice(0, Math.max(0, free)).forEach(function(job) { void startJob(job); });
		}
		async function refresh() {
			if (busy) { pending = true; return; }
			const selected = uplink.value === 'all' ? uplinks : uplinks.filter(function(item) { return item.id === uplink.value; });
			if (!selected.length) { message.textContent = _('请先在校园网设置中添加上游。'); return; }
			jobs = selected.map(function(item) { return { uplink: item.id, account: account.value || 'current', started: false, running: false, ticket: '', item: null,
				content: E('div', {}, _('等待查询…')), title: [item.id, item.network, item.device].filter(Boolean).join(' · ') }; });
			details.replaceChildren.apply(details, jobs.map(function(job) { return E('div', { 'class': 'cbi-section', style: 'padding:16px;min-width:0;overflow-wrap:anywhere' }, [E('h3', {}, job.title), job.content]); }));
			updateSummary(); pump();
		}
		uplink.addEventListener('change', refresh); account.addEventListener('change', refresh);
		function overview(item) {
			return [row(_('账号'), item.account), row(_('登录方式'), item.access), row(_('余额'), item.balance === '' ? '' : item.balance + ' 元'), row(_('剩余流量'), item.remainingFlow === '' ? '' : item.remainingFlow + ' MB'), row(_('状态'), item.accountStatus), row(_('套餐'), item.package)];
		}
		function showCaptcha(job, item) {
			const input = E('input', { type: 'text', maxlength: 12, autocomplete: 'off', placeholder: _('验证码'), 'class': 'cbi-input-text' });
			const image = E('img', { src: item.image, alt: _('计费系统验证码'), style: 'max-width:100%;width:240px;display:block;margin:12px 0' });
			async function answer(refreshImage) {
				if (job.running) return;
				job.running = true; updateSummary();
				try {
					const next = await captcha(job.ticket, L.env.sessionid, input.value.trim(), refreshImage);
					if (next.state === 'error') throw new Error(next.message);
					job.content.textContent = next.message;
				} catch (error) { job.running = false; job.content.textContent = String(error.message || error); updateSummary(); }
			}
			job.content.replaceChildren(E('p', {}, item.message), image, input, E('div', { style: 'display:flex;gap:12px;margin-top:12px' }, [
				E('button', { type: 'button', 'class': 'btn', click: function() { void answer(true); } }, _('换一张')),
				E('button', { type: 'button', 'class': 'btn cbi-button-action', click: function() { void answer(false); } }, _('继续'))]));
		}
		poll.add(async function() {
			await Promise.all(jobs.filter(function(job) { return job.running && job.ticket; }).map(async function(job) {
				try {
					const response = await result(job.ticket, L.env.sessionid), item = response.result || response;
					if (item.account) job.item = item;
					if (item.state === 'captcha') { job.running = false; showCaptcha(job, item); }
					else {
						const cards = item.account ? overview(item) : [];
						cards.unshift(E('p', {}, item.message + (item.state === 'loading' ? ' · ' + (item.percent || 0) + '%' : '')));
						if (item.state !== 'loading') job.running = false;
						if (item.state === 'ready') {
							cards.push(E('h4', {}, _('在线设备')));
							(response.sessions || []).forEach(function(session) { cards.push(E('div', {}, [row('IPv4', session.ip), row('IPv6', session.ipv6), row('MAC', session.mac), row(_('在线时长'), session.useTime ? Math.round(Number(session.useTime) / 60) + ' ' + _('分钟') : '')])); });
							if (!(response.sessions || []).length) cards.push(E('p', {}, response.sessionsAvailable ? _('暂无在线设备。') : _('在线设备暂时无法查询，请稍后刷新。')));
						}
						job.content.replaceChildren.apply(job.content, cards);
					}
				} catch (error) { job.running = false; job.content.textContent = _('查询未完成：') + String(error.message || error); }
			}));
			updateSummary(); pump();
		}, 2);
		Promise.resolve().then(refresh);
		return E('div', { 'class': 'cbi-map' }, [E('h2', {}, _('计费系统')), E('p', {}, _('自动查询各条上游的当前账号，也可选择已保存账号。')), selectors, message, summary, details]);
	}
});
