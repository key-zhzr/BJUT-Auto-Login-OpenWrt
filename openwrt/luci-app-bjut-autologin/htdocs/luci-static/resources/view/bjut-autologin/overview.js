'use strict';
'require view';
'require bjut-autologin.client as client';
'require bjut-autologin.traffic as traffic';
'require bjut-autologin.workbench as bjut';
return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
	load: function() { return client.call('dashboard'); },
	render: function(data) {
		const summary = E('p'),
			statePill = E('span', { 'class': 'bj-badge info' }, _('守护运行中')),
			message = E('p', { 'class': 'bj-status-banner', 'role': 'status' }),
			refreshBtn = E('button', { 'class': 'btn btn-sm', type: 'button' }, _('立即刷新'));
		let checking = false, watcher, last = data;
		function action(name) {
			return function(uplink, account) { return client.call(name, { uplink: uplink, account: account || '' }); };
		}
		const grid = bjut.portGrid({
			login: action('login'),
			logout: action('logout'),
			switchAccount: action('switch_account'),
			changed: function() { return watcher.refresh(); }
		});
		function draw(next) {
			last = next;
			const list = next.status.uplinks || [];
			checking = list.some(function(item) { return item.checking; });
			const connectedCount = list.filter(function(item) {
				return item.state === 'online' || item.state === 'authenticated_limited';
			}).length;
			const anyStale = list.some(function(item) { return item.stale; });
			summary.textContent = _('已连接上游') + ' ' + connectedCount + ' / ' + list.length;
			statePill.className = 'bj-badge ' + (anyStale ? 'warn' : checking ? 'info' : connectedCount === list.length && list.length > 0 ? 'ok' : 'info');
			statePill.textContent = anyStale ? _('上次数据') : checking ? _('正在检测…') : connectedCount === list.length && list.length > 0 ? _('全部在线') : _('自动守护中');
			grid.render(next.status, next.ports, next.accounts);
		}
		refreshBtn.addEventListener('click', function() {
			if (watcher) void watcher.refresh();
		});
		const hero = E('section', { 'class': 'bj-card bj-overview-hero bj-enter' }, [
			E('div', { 'class': 'bj-overview-hero-main' }, [summary, statePill]),
			E('div', { 'class': 'bj-actions', style: 'margin:0' }, [refreshBtn])
		]);
		const root = E('div', { 'class': 'bjut-workbench' }, [
			bjut.style(),
			message,
			hero,
			E('section', { 'class': 'bj-card' }, [E('h3', {}, _('端口状态')), grid.element])
		]);
		draw(data);
		watcher = client.watch(root, async function() {
			try {
				draw(await client.call('dashboard'));
				message.textContent = '';
				message.className = 'bj-status-banner';
			} catch (error) {
				draw(Object.assign({}, last, {
					status: Object.assign({}, last.status, {
						uplinks: (last.status.uplinks || []).map(function(item) { return Object.assign({}, item, { stale: 1 }); })
					})
				}));
				message.className = 'bj-status-banner is-error';
				message.textContent = _('状态读取失败，将自动重试：') + String(error.message || error);
			}
		}, function() { return checking ? 1 : 2; });
		root.append(traffic.render());
		return bjut.disclosures(root);
	}
});
