'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require tools.widgets as widgets';
'require bjut-autologin.workbench as bjut';
'require bjut-autologin.maintenance as maintenance';
'require bjut-autologin.account-order as accountOrder';

const testPushPlus = rpc.declare({ object: 'bjut-autologin', method: 'pushplus_test' });
const queryPushPlusStatus = rpc.declare({ object: 'bjut-autologin', method: 'pushplus_status' });

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('bjut-autologin'),
			queryPushPlusStatus().catch(function() { return {}; })
		]);
	},

	render: function(loaded) {
		let m, s, o;
		const initialPushPlus = Array.isArray(loaded) && loaded[1] ? loaded[1] : {};

		m = new form.Map('bjut-autologin', _('BJUT 自动登录'),
			_('自动维护校园网登录，分别管理各条上游与账号。'));

		s = m.section(form.NamedSection, 'main', 'service', _('服务设置'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用服务'));
		o.rmempty = false;

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
		o.default = '3';
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
		o.description = _('首次联网复核未通过时，等待后再检查。');

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
		o.value('trace', _('详细跟踪'));
		o.value('debug', _('调试'));
		o.value('info', _('信息'));
		o.value('notice', _('通知'));
		o.value('warning', _('警告'));
		o.value('error', _('仅错误'));
		o.default = 'info';

		o = s.option(form.ListValue, 'log_target', _('日志保存位置'));
		o.value('system', _('系统日志')); o.value('file', _('自定义目录')); o.default = 'system'; o.rmempty = false;
		o = s.option(form.Value, 'log_directory', _('日志目录'));
		o.default = '/tmp/bjut-autologin-log'; o.depends('log_target','file'); o.rmempty = false;
		o.description = _('可选择 /tmp、/var/log 或存储设备上的目录。');
		o.validate = function(section,value) { return /^\/(tmp|var\/log|mnt|media|overlay|srv|data)\/[-A-Za-z0-9_./]+$/.test(value) && !/(^|\/)\.\.?(\/|$)|\/\//.test(value) && !value.endsWith('/') ? true : _('请输入有效的日志目录'); };
		o = s.option(form.Flag, 'log_web', _('通过网页查看日志'));
		o.depends('log_target','file'); o.default = '0'; o.rmempty = false;
		o.description = _('自动建立 /www/bjut-autologin.log 链接；局域网内可直接访问。');
		o = s.option(form.Value, 'log_max_kb', _('单份日志大小（KB）'));
		o.default = '256'; o.datatype = 'range(64,4096)'; o.depends('log_target','file'); o.rmempty = false;
		o.description = _('达到上限后轮换，保留一份旧日志。');

		o = s.option(form.Flag, 'managed_routes', _('固定上游路由'));
		o.default = o.enabled; o.rmempty = false;
		o.description = _('为指定设备的请求使用独立出口，适用于多个上游或关闭了默认路由的接口。');

		o = s.option(form.Flag, 'mwan3', _('兼容 mwan3'));
		o.default = o.enabled; o.rmempty = false;
		o.description = _('为所选出口添加专用规则，保留其他流量的分流设置。');

		o = s.option(form.Flag, 'pushplus_enabled', _('PushPlus 消息推送'));
		o.default = '0'; o.rmempty = false;
		o.description = _('接收登录成功、恢复联网和上游异常提醒。');
		o = s.option(form.Value, 'pushplus_token', _('PushPlus 令牌'));
		o.password = true; o.depends('pushplus_enabled', '1'); o.rmempty = false; o.retain = true;
		o.description = _('填写 PushPlus 的用户令牌或消息令牌。');
		o.validate = function(section, value) {
			return /^[A-Za-z0-9_-]{1,256}$/.test(value) ? true : _('请填写有效的 PushPlus 令牌');
		};
		o = s.option(form.Value, 'pushplus_topic', _('群组编码（可选）'));
		o.depends('pushplus_enabled', '1'); o.retain = true;
		o.description = _('留空时仅发送给自己。');
		o.validate = function(section, value) {
			return /^[A-Za-z0-9_-]{0,64}$/.test(value) ? true : _('请填写有效的群组编码');
		};
		o = s.option(form.Flag, 'pushplus_online', _('登录与恢复提醒'));
		o.depends('pushplus_enabled', '1'); o.default = '1'; o.rmempty = false; o.retain = true;
		o = s.option(form.Flag, 'pushplus_failure', _('异常提醒'));
		o.depends('pushplus_enabled', '1'); o.default = '1'; o.rmempty = false; o.retain = true;
		o = s.option(form.Value, 'pushplus_delay', _('异常持续时间（秒）'));
		o.depends('pushplus_enabled', '1'); o.default = '60'; o.datatype = 'range(10,3600)'; o.rmempty = false; o.retain = true;
		o.description = _('短暂断网不提醒；账号被拒绝等明确错误会立即提醒。');
		o = s.option(form.Value, 'pushplus_interval', _('重复提醒间隔（秒）'));
		o.depends('pushplus_enabled', '1'); o.default = '3600'; o.datatype = 'range(60,86400)'; o.rmempty = false; o.retain = true;
		const pushplusSummary = E('strong', { 'class': 'bj-pushplus-summary' });
		const pushplusDetail = E('p', { 'class': 'bj-pushplus-detail' });
		let pushplusPolling = false, pushplusTimer = null;
		async function refreshPushPlusStatus() {
			if (pushplusPolling) return null;
			pushplusPolling = true;
			try {
				const next = await queryPushPlusStatus();
				renderPushPlusStatus(next);
				return next;
			} catch (error) {
				pushplusDetail.textContent = _('状态读取失败：') + String(error.message || error);
				return null;
			} finally {
				pushplusPolling = false;
			}
		}
		const pushplusRefreshBtn = E('button', {
			'class': 'btn cbi-button',
			type: 'button',
			click: function() { void refreshPushPlusStatus(); }
		}, _('刷新测试状态'));
		const pushplusBox = E('div', {
			'class': 'bj-pushplus-status',
			'role': 'status',
			'data-state': 'idle'
		}, [
			E('div', { 'class': 'bj-actions' }, [pushplusSummary, pushplusRefreshBtn]),
			pushplusDetail
		]);
		function renderPushPlusStatus(info) {
			const data = info || {};
			const state = data.state || 'idle';
			const http = data.httpStatus || (state === 'accepted' ? '200' : state === 'error' ? '000' : '');
			const code = data.apiCode || (state === 'accepted' ? '200' : '');
			pushplusBox.setAttribute('data-state', state);
			if (state === 'queued') {
				pushplusSummary.textContent = _('排队中');
				pushplusDetail.textContent = data.message || _('测试消息排队发送中，等待后台连接 PushPlus。');
			} else if (state === 'accepted') {
				pushplusSummary.textContent = _('已受理（HTTP ') + http + _(' / 业务码 ') + code + _(' · 已受理不等于已送达）');
				pushplusDetail.textContent = data.message || _('PushPlus 已受理（HTTP 200 / 业务码 200）；平台异步投递，已受理不等于已送达。');
			} else if (state === 'error') {
				pushplusSummary.textContent = _('请求失败（HTTP ') + http + _(' / 业务码 ') + (code || _('未知')) + _('）');
				pushplusDetail.textContent = data.message || _('推送请求失败，将在冷却后重试。');
			} else {
				pushplusSummary.textContent = _('未发送测试');
				pushplusDetail.textContent = data.message || _('尚未发送测试消息；点击发送测试消息后可查看排队、HTTP/业务码或受理状态。');
			}
		}
		function pollPushPlusUntilSettled(remaining) {
			if (pushplusTimer !== null) {
				window.clearTimeout(pushplusTimer);
				pushplusTimer = null;
			}
			if (remaining <= 0) return;
			pushplusTimer = window.setTimeout(async function() {
				pushplusTimer = null;
				if (!pushplusBox.isConnected) return;
				const next = await refreshPushPlusStatus();
				if (next && next.state === 'queued') pollPushPlusUntilSettled(remaining - 1);
			}, 400);
		}
		renderPushPlusStatus(initialPushPlus);
		o = s.option(form.Button, '_pushplus_test', _('测试推送'));
		o.depends('pushplus_enabled', '1'); o.inputtitle = _('发送测试消息'); o.inputstyle = 'action';
		o.description = _('请先保存并应用设置。');
		o.onclick = async function() {
			try {
				const result = await testPushPlus();
				if (result && result.testStatus) renderPushPlusStatus(result.testStatus);
				else await refreshPushPlusStatus();
				ui.addNotification(null, E('p', {}, result.message || _('无法发送测试消息')), result.state === 'ready' ? 'info' : 'error');
				if (result && result.state === 'ready') pollPushPlusUntilSettled(6);
			} catch (error) { ui.addNotification(null, E('p', {}, String(error)), 'error'); }
		};
		const PushPlusStatusControl = form.Value.extend({
			renderWidget: function() { return pushplusBox; },
			formvalue: function() { return null; }
		});
		o = s.option(PushPlusStatusControl, '_pushplus_status', _('测试推送状态'));
		o.depends('pushplus_enabled', '1');
		o.description = _('显示排队、请求失败的 HTTP 与业务码、或平台已受理状态（异步投递，已受理不等于最终送达）。');

		o = s.option(form.Flag, 'prefer_remaining_flow', _('优先使用余量充足的账号'));
		o.default='0';o.rmempty=false;o.description=_('仅在未指定独立顺序时使用新鲜计费数据排序。');
		o = s.option(form.Flag, 'traffic_monitor', _('设备流量统计'));
		o.default='0';o.rmempty=false;o.description=_('开启后每分钟记录计费流量并绘制曲线。');
        o.cfgvalue=function(section){return ['local','all'].includes(uci.get('bjut-autologin',section,'traffic_scope'))?(uci.get('bjut-autologin',section,'traffic_monitor')||'0'):'0';};
        o = s.option(form.ListValue, 'traffic_scope', _('流量统计范围'));
        o.value('local',_('仅路由器上游'));o.value('all',_('全部在线设备'));o.default='local';o.rmempty=false;

		o = s.option(form.Flag, 'billing_background', _('后台计费检查'));
		o.default = '0'; o.rmempty = false;
		o.description = _('定期检查各账号余额和流量，App 关闭后也可运行。');
		o = s.option(form.Value, 'billing_interval', _('计费检查间隔（秒）'));
		o.depends('billing_background','1'); o.default='21600'; o.datatype='range(900,86400)'; o.rmempty=false; o.retain=true;
		o = s.option(form.Flag, 'billing_alerts', _('用量不足时通过 PushPlus 提醒'));
		o.depends('billing_background','1'); o.default='1'; o.rmempty=false; o.retain=true;
		o = s.option(form.Value, 'balance_threshold', _('余额提醒线（元）'));
		o.depends('billing_background','1'); o.default='5'; o.datatype='ufloat'; o.rmempty=false; o.retain=true;
		o = s.option(form.Button, '_maintenance', _('路由器备份与更新'));
		o.inputtitle=_('打开'); o.inputstyle='action'; o.onclick=function(){return maintenance.show();};
		o = s.option(form.Value, 'flow_threshold', _('流量提醒线（GB）'));
		o.depends('billing_background','1'); o.default='5'; o.datatype='ufloat'; o.rmempty=false; o.retain=true;

		s = m.section(form.GridSection, 'uplink', _('上游接口'));
		s.anonymous = false; s.addremove = true; s.sortable = true;
		s.description = _('每条上游独立检测、认证与重试。IPv6 接口留空时跟随 IPv4 设备。');
		o = s.option(form.Flag, 'enabled', _('启用')); o.default = o.enabled; o.rmempty = false;
		o = s.option(widgets.NetworkSelect, 'network', _('IPv4 接口')); o.rmempty = false; o.nocreate = true;
		o = s.option(widgets.NetworkSelect, 'network6', _('IPv6 接口')); o.nocreate = true; o.optional = true;
		o = s.option(form.Value, 'device', _('IPv4 设备')); o.placeholder = _('自动'); o.modalonly = true;
		o = s.option(form.Value, 'device6', _('IPv6 设备')); o.placeholder = _('自动'); o.modalonly = true;
		o = s.option(form.Value, 'source4', _('IPv4 源地址')); o.datatype = 'ip4addr'; o.modalonly = true;
		o = s.option(form.Value, 'source6', _('IPv6 源地址')); o.datatype = 'ip6addr'; o.modalonly = true;
		o = s.option(form.ListValue, 'transport', _('传输类型'));
		o.value('auto', _('自动')); o.value('ethernet', _('有线')); o.value('wifi', _('Wi-Fi')); o.default = 'auto';
		o = s.option(form.ListValue, 'login_type', _('认证方式'));
		o.value('auto', _('自动')); o.value('type1', 'bjut-sushe'); o.value('type2', 'bjut_wifi'); o.value('type3', 'lgn'); o.default = 'auto';
		const accountChoices=[];
		uci.sections('bjut-autologin', 'account', function(account) { accountChoices.push({id:account['.name'],user:account.username || account['.name'],enabled:account.enabled!=='0'}); });
		const OrderedAccounts=form.Value.extend({
			renderWidget:function(section_id,option_index,cfgvalue){return accountOrder.create(accountChoices,cfgvalue,this.cbid(section_id),this.readonly || this.map.readonly);},
			formvalue:function(section_id){const root=this.map.findElement('id',this.cbid(section_id));return root?accountOrder.read(root):this.cfgvalue(section_id);},
			textvalue:function(section_id){const names=accountOrder.ids(this.cfgvalue(section_id)).map(function(id){const account=accountChoices.find(function(item){return item.id===id;});return account?account.user:id;});return names.length?names.join(' → '):_('跟随账号管理');}
		});
		o = s.option(OrderedAccounts, 'accounts', _('自动登录顺序'));
		o.description = _('勾选账号并用箭头调整此接口的顺序；不选则跟随账号管理。');
		o = s.option(form.Value, 'expected_ssid', _('SSID')); o.modalonly = true;
		o = s.option(form.Value, 'expected_bssid', _('BSSID')); o.modalonly = true;

		return m.render().then(function(root){root.append(bjut.style());return root;});
	}
});
