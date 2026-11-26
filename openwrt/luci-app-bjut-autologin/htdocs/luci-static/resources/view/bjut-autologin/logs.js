'use strict';
'require view';
'require rpc';
'require bjut-autologin.client as client';
'require bjut-autologin.workbench as bjut';
const logs = function() { return client.call('logs', {}); };
const severity = {
	err: 'error', error: 'error', crit: 'error', alert: 'error', emerg: 'error',
	warn: 'warn', warning: 'warn', notice: 'warn', info: 'info', debug: 'debug', trace: 'debug'
};

function lineMatchesLevel(line, level) {
	const prefix = line.match(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s+\[([a-z]+)\]/i)
		|| line.match(/(?:^|\s)bjut-autologin(?:\[\d+\])?:\s+\[([a-z]+)\]/i)
		|| line.match(/\bdaemon\.([a-z]+)\s+bjut-autologin(?:\[\d+\])?:/i);
	return !!prefix && severity[prefix[1].toLowerCase()] === level;
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
	load: function() { return logs(); },
	render: function(data) {
		let rawText = data.text || '';
		const content = E('pre', { 'class': 'bj-log' }, rawText || _('暂无日志。')),
			searchInput = E('input', { type: 'search', placeholder: _('搜索日志关键字…'), 'aria-label': _('搜索日志关键字') }),
			levelSelect = E('select', { 'aria-label': _('按日志级别筛选') }, [
				['all', _('全部级别')],
				['error', _('仅错误')],
				['warn', _('警告')],
				['info', _('信息')],
				['debug', _('调试 / 跟踪')]
			].map(function(pair) { return E('option', { value: pair[0] }, pair[1]); })),
			counter = E('span', { 'class': 'bj-badge' }),
			status = E('p', { 'class': 'bj-status-banner', role: 'status' }),
			copyBtn = E('button', { 'class': 'btn btn-sm', type: 'button' }, _('复制日志')),
			bottomBtn = E('button', { 'class': 'btn btn-sm', type: 'button' }, _('跳到底部')),
			refreshBtn = E('button', { 'class': 'btn btn-sm', type: 'button' }, _('刷新'));
		let busy = false;
		function applyFilter(preserveScroll) {
			const follow = content.scrollTop + content.clientHeight >= content.scrollHeight - 20;
			const prevTop = content.scrollTop;
			const allLines = rawText ? rawText.split(/\r?\n/).filter(Boolean) : [];
			const q = searchInput.value.trim().toLowerCase();
			const level = levelSelect.value || 'all';
			const filtered = (!q && level === 'all')
				? allLines
				: allLines.filter(function(line) {
					return (level === 'all' || lineMatchesLevel(line, level)) && (!q || line.toLowerCase().includes(q));
				});
			const nextDisplay = filtered.length
				? filtered.join('\n')
				: (allLines.length ? _('没有匹配的日志记录。') : _('暂无日志。'));
			if (content.textContent !== nextDisplay) {
				content.textContent = nextDisplay;
				if (preserveScroll) {
					content.scrollTop = follow ? content.scrollHeight : prevTop;
				}
			}
			counter.textContent = (!q && level === 'all')
				? _('共 ') + allLines.length + _(' 条')
				: _('匹配 ') + filtered.length + ' / ' + allLines.length + _(' 条');
		}
		async function refresh() {
			if (busy) return;
			busy = true;
			try {
				const next = await logs();
				status.textContent = '';
				const incoming = next.text || '';
				if (incoming !== rawText) {
					rawText = incoming;
					applyFilter(true);
				}
			} catch (error) {
				status.textContent = String(error.message || error);
			} finally {
				busy = false;
			}
		}
		searchInput.addEventListener('input', function() { applyFilter(false); });
		levelSelect.addEventListener('change', function() { applyFilter(false); });
		refreshBtn.addEventListener('click', function() { void refresh(); });
		bottomBtn.addEventListener('click', function() { content.scrollTop = content.scrollHeight; });
		copyBtn.addEventListener('click', function() {
			void bjut.copyText(content.textContent || '').then(function() {
				copyBtn.textContent = _('已复制');
			}).catch(function() {
				copyBtn.textContent = _('请手动复制');
			}).finally(function() {
				window.setTimeout(function() { copyBtn.textContent = _('复制日志'); }, 1500);
			});
		});
		applyFilter(false);
		const root = E('div', { 'class': 'bjut-workbench' }, [
			bjut.style(),
			E('section', { 'class': 'bj-card' }, [
				E('div', { 'class': 'bj-log-toolbar' }, [
					E('div', { 'class': 'bj-log-filters' }, [searchInput, levelSelect, counter]),
					E('div', { 'class': 'bj-log-actions' }, [copyBtn, bottomBtn, refreshBtn])
				]),
				status,
				content
			])
		]);
		client.watch(root, refresh, 2);
		return root;
	}
});
