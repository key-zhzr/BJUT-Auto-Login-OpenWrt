'use strict';
'require view';
'require form';
'require fs';
'require tools.widgets as widgets';

const STATUS_PATH = '/var/run/bjut-autologin/status.json';

function readStatus() {
	return L.resolveDefault(fs.read(STATUS_PATH), null).then(function(text) {
		if (!text)
			return null;
		try {
			return JSON.parse(text);
		}
		catch (error) {
			return null;
		}
	});
}

function statusLabel(state) {
	const labels = {
		stopped: _('未运行'),
		online: _('互联网已连接'),
		offline_suspected: _('正在复核离线状态'),
		cooldown: _('等待安全重试'),
		waiting_interface: _('等待上游接口'),
		portal_not_found: _('未发现认证门户'),
		portal_not_ready: _('认证门户尚未就绪'),
		blocked: _('安全策略已阻止'),
		login_accepted: _('登录已受理，等待复核'),
		auth_rejected: _('账号被拒绝'),
		no_account: _('没有适用账号'),
		request_failed: _('认证结果不明确')
	};
	return labels[state] || state || _('未知');
}

function statusPanel(status) {
	if (!status) {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行状态')),
			E('p', {}, _('尚无运行状态。保存并应用配置、启用服务后再刷新本页。'))
		]);
	}

	const rows = [
		[_('状态'), statusLabel(status.state)],
		[_('说明'), status.message || '-'],
		[_('上游'), [status.network, status.device, status.ipv4].filter(Boolean).join(' / ') || '-'],
		[_('网络身份'), [status.transport, status.ssid, status.bssid].filter(Boolean).join(' / ') || '-'],
		[_('认证协议'), status.protocol || '-'],
		[_('最近账号'), status.account || '-'],
		[_('更新时间'), status.updated_at ? new Date(status.updated_at * 1000).toLocaleString() : '-'],
		[_('下次重试'), status.next_attempt ? new Date(status.next_attempt * 1000).toLocaleString() : '-']
	];

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('运行状态')),
		E('div', { 'class': 'table' }, rows.map(function(row) {
			return E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td left', 'style': 'width:25%' }, row[0]),
				E('div', { 'class': 'td left' }, row[1])
			]);
		}))
	]);
}

return view.extend({
	load: function() {
		return readStatus();
	},

	render: function(status) {
		let m, s, o;

		m = new form.Map('bjut-autologin', _('BJUT 自动登录'),
			_('面向 OpenWrt/ImmortalWrt 的低占用校园网认证服务。认证请求固定到所选上游接口，并在发送凭据前执行只读协议探测。'));

		s = m.section(form.NamedSection, 'main', 'service', _('服务设置'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用服务'));
		o.rmempty = false;

		o = s.option(widgets.NetworkSelect, 'network', _('上游逻辑接口'));
		o.rmempty = false;
		o.nocreate = true;
		o.description = _('通常为连接校园网的 wwan 或 wan，而不是 lan。所有请求都会绑定到该接口对应的 Linux 设备。');

		o = s.option(form.Value, 'device', _('Linux 设备覆盖'));
		o.placeholder = _('自动读取');
		o.description = _('通常留空；仅当逻辑接口报告的 l3_device 不正确时填写，例如 phy0-sta0。');
		o.validate = function(sectionId, value) {
			return !value || /^[A-Za-z0-9_.:@-]+$/.test(value) ? true : _('设备名包含无效字符');
		};

		o = s.option(form.ListValue, 'transport', _('传输类型'));
		o.value('auto', _('自动判断'));
		o.value('wifi', _('Wi-Fi 上游'));
		o.value('ethernet', _('有线上游'));
		o.default = 'auto';

		o = s.option(form.ListValue, 'login_type', _('认证协议'));
		o.value('auto', _('自动探测'));
		o.value('type1', _('bjut-sushe（宿舍网）'));
		o.value('type2', _('bjut_wifi（公共无线网）'));
		o.value('type3', _('lgn（有线 IPv4 + IPv6）'));
		o.default = 'auto';

		o = s.option(form.ListValue, 'compatibility', _('安全兼容模式'));
		o.value('secure', _('安全模式（推荐）'));
		o.value('legacy_http', _('旧式 HTTP（明文凭据）'));
		o.default = 'secure';
		o.description = _('安全模式使用 TLS、固定网关地址及宿舍网证书公钥固定。旧式 HTTP 仅用于网关确实不支持 HTTPS 的情况；无线使用时还必须填写精确 BSSID。');

		o = s.option(form.Flag, 'strict_network', _('严格校验网络身份'));
		o.default = o.enabled;
		o.rmempty = false;
		o.description = _('要求校园网地址、正确传输类型以及匹配的 SSID/BSSID；建议保持开启。');

		o = s.option(form.Value, 'expected_ssid', _('预期 SSID'));
		o.placeholder = _('留空时使用内置 BJUT 名称规则');
		o.description = _('填写后采用区分大小写的精确匹配。');

		o = s.option(form.Value, 'expected_bssid', _('预期 BSSID'));
		o.placeholder = 'aa:bb:cc:dd:ee:ff';
		o.description = _('可选的精确 AP 地址限制；无线旧式 HTTP 模式下必填。');
		o.validate = function(sectionId, value) {
			return !value || /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(value) ? true : _('BSSID 格式无效');
		};

		o = s.option(form.Value, 'interval', _('检测间隔（秒）'));
		o.datatype = 'range(5,3600)';
		o.default = '20';
		o.rmempty = false;

		o = s.option(form.Value, 'timeout', _('单次连接超时（秒）'));
		o.datatype = 'range(1,30)';
		o.default = '5';
		o.rmempty = false;

		o = s.option(form.Value, 'offline_confirmations', _('离线确认次数'));
		o.datatype = 'range(1,10)';
		o.default = '2';
		o.rmempty = false;
		o.description = _('连续达到该次数才探测门户，避免网络瞬时抖动触发登录。');

		o = s.option(form.Value, 'max_backoff', _('最大退避（秒）'));
		o.datatype = 'range(5,86400)';
		o.default = '300';
		o.rmempty = false;

		o = s.option(form.Value, 'credential_cooldown', _('账号拒绝冷却（秒）'));
		o.datatype = 'range(30,86400)';
		o.default = '600';
		o.rmempty = false;

		o = s.option(form.Value, 'post_login_delay', _('登录后复核延迟（秒）'));
		o.datatype = 'range(0,15)';
		o.default = '2';
		o.rmempty = false;
		o.description = _('网关接受登录后等待该时长，再检查互联网是否恢复。');

		o = s.option(form.Value, 'online_url', _('联网检测 URL'));
		o.default = 'http://connect.rom.miui.com/generate_204';
		o.rmempty = false;
		o.validate = function(sectionId, value) {
			return /^https?:\/\/[^\s"\\]+$/.test(value) ? true : _('请输入不含空格的 HTTP(S) URL');
		};

		o = s.option(form.Value, 'online_code', _('联网成功 HTTP 状态码'));
		o.datatype = 'range(100,599)';
		o.default = '204';
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('日志级别'));
		o.value('debug', _('调试'));
		o.value('info', _('信息'));
		o.value('notice', _('通知'));
		o.value('error', _('仅错误'));
		o.default = 'notice';

		s = m.section(form.GridSection, 'account', _('账号'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.description = _('账号按此处顺序尝试。只有网关明确返回拒绝时才会切换下一个账号；超时或响应不明确时不会轮换。密码以明文保存在仅 root 可读的 UCI 文件中。');

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.option(form.Value, 'username', _('账号'));
		o.rmempty = false;

		o = s.option(form.Value, 'password', _('密码'));
		o.password = true;
		o.modalonly = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'login_type', _('适用协议'));
		o.value('auto', _('全部 / 自动'));
		o.value('type1', _('仅 bjut-sushe'));
		o.value('type2', _('仅 bjut_wifi'));
		o.value('type3', _('仅 lgn 有线'));
		o.default = 'auto';

		return m.render().then(function(mapNode) {
			return E([], [statusPanel(status), mapNode]);
		});
	}
});
