'use strict';
'require view';
'require rpc';
'require bjut-autologin.client as client';
'require bjut-autologin.workbench as bjut';
const status = function() { return client.call('status', {}); };
return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
	load: function() { return status(); },
	render: function(data) {
		let latest = data;
		const content = E('div', { 'class': 'bj-diag-grid bj-enter' }),
			message = E('p', { style: 'margin:0' }, _('展示各条上游最近一次探测与路由状态。'));
		function advice(item) {
			if (item.stale) return _('结果已过期，请检查路由器 bjut-autologin 服务状态。');
			if (item.route4 === 'failed' || item.route6 === 'failed' || item.route4 === 'missing_default') return _('上游出口未就绪，请检查接口网关和策略路由。');
			if (item.state === 'auth_rejected') return _('请核对账号密码、账户余额和停机状态。');
			if (item.state === 'account_busy') return _('账号已达到同时在线上限，可改用备用账号。');
			if (item.state === 'waiting_interface') return _('上游尚未取得地址，请检查网线连接或 Wi-Fi。');
			if (item.session === 'online' && item.internet4 !== 'reachable' && item.internet6 !== 'reachable') return _('认证已通过但外网访问失败，请检查出口路由、DNS 与网关。');
			if (item.internet4 === 'reachable' && item.internet6 === 'unreachable') return _('IPv4 正常，IPv6 未连接；请检查 IPv6 地址、默认路由与双栈认证。');
			return item.state === 'online' ? _('此上游连接正常。') : _('可结合控制台端口详情与本机诊断排查。');
		}
		function badgeClass(item) {
			if (item.stale) return 'warn';
			if (item.state === 'online') return 'ok';
			if (['auth_rejected', 'portal_not_found', 'blocked'].includes(item.state)) return 'error';
			return 'info';
		}
		function cardTone(item) {
			if (item.stale) return '';
			if (item.state === 'online') return 'is-online';
			if (['auth_rejected', 'portal_not_found', 'blocked'].includes(item.state)) return 'is-error';
			return '';
		}
		function draw(next) {
			latest = next;
			const family = function(value) { return value === 'reachable' ? _('通过') : value === 'unreachable' ? _('未通过') : value === 'not_configured' ? _('未取得地址') : _('待检测'); };
			const route = function(value) { return { managed: _('固定出口'), kernel: _('系统路由'), missing_default: _('缺少默认路由'), failed: _('出口未就绪'), not_configured: _('未取得地址') }[value] || _('待检查'); };
			content.replaceChildren.apply(content, (next.uplinks || []).map(function(item) {
				const title = [item.device, item.network].filter(Boolean).join(' · ') || item.id;
				const label = item.stale ? _('数据已过期') : bjut.label(item.state);
				const sessionText = item.session === 'online' ? _('认证会话：已认证') : item.session === 'offline' ? _('认证会话：未认证') : _('认证会话：待确认');
				return E('article', { 'class': ['bj-card bj-diag-card', cardTone(item)].filter(Boolean).join(' ') }, [
					E('div', { 'class': 'bj-diag-head' }, [
						E('h3', {}, title),
						E('span', { 'class': 'bj-badge ' + badgeClass(item) }, label)
					]),
					E('div', { 'class': 'bj-kv-list' }, [
						E('p', {}, 'IPv4 ' + family(item.internet4) + ' · IPv6 ' + family(item.internet6)),
						E('p', {}, 'IPv4 ' + route(item.route4) + ' · IPv6 ' + route(item.route6)),
						E('p', {}, sessionText)
					]),
					E('p', { 'class': 'bj-advice-callout' }, advice(item)),
					E('p', { 'class': 'bj-diag-time' }, item.updated_at ? _('更新时间：') + new Date(item.updated_at * 1000).toLocaleString() : _('尚无检测结果'))
				]);
			}));
		}
		async function refresh() {
			try {
				draw(await status());
				message.textContent = _('已更新各上游检测结果。');
			} catch (error) {
				draw(Object.assign({}, latest, {
					uplinks: (latest.uplinks || []).map(function(item) { return Object.assign({}, item, { stale: 1 }); })
				}));
				message.textContent = _('暂时无法连接路由服务，显示上次结果。');
			}
		}
		function exportReport() {
			const report = {
				apiVersion: 1,
				generatedAt: new Date().toISOString(),
				version: latest.version,
				uplinks: (latest.uplinks || []).map(function(item) {
					const row = {};
					for (const key of ['id', 'device', 'network', 'state', 'session', 'internet4', 'internet6', 'route4', 'route6', 'updated_at', 'age_seconds', 'stale']) row[key] = item[key];
					row.advice = advice(item);
					return row;
				})
			};
			const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2)], { type: 'application/json' })),
				a = E('a', { href: url, download: 'BJUT-AL-路由诊断.json' });
			a.click();
			window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
		}
		const copyBtn = E('button', {
			'class': 'btn btn-sm',
			type: 'button',
			click: function() {
				const lines = (latest.uplinks || []).map(function(item) {
					return [item.device || item.id, item.network, item.stale ? '数据已过期' : bjut.label(item.state), 'IPv4=' + item.internet4, 'IPv6=' + item.internet6, advice(item)].filter(Boolean).join(' | ');
				});
				void bjut.copyText(lines.join('\n')).then(function() {
					copyBtn.textContent = _('已复制');
					window.setTimeout(function() { copyBtn.textContent = _('复制摘要'); }, 1500);
				}).catch(function() {
					message.textContent = _('复制失败，请使用导出诊断包。');
				});
			}
		}, _('复制摘要'));
		draw(data);
		const root = E('div', { 'class': 'bjut-workbench' }, [
			bjut.style(),
			E('div', { 'class': 'bj-card bj-header' }, [
				message,
				E('div', { 'class': 'bj-actions', style: 'margin:0' }, [
					E('button', { 'class': 'btn btn-sm', type: 'button', click: function() { void watcher.refresh(); } }, _('刷新')),
					copyBtn,
					E('button', { 'class': 'btn btn-sm bj-primary', type: 'button', click: exportReport }, _('导出诊断包'))
				])
			]),
			content
		]);
		const watcher = client.watch(root, refresh, 2);
		return root;
	}
});
