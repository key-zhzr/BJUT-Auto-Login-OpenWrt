'use strict';
'require baseclass';

const labels = { online:'互联网已连接', authenticated_limited:'已认证，探测受限', probe_uncertain:'连通性待确认', offline_suspected:'正在复核', busy:'正在检测', waiting_interface:'等待接口', cooldown:'等待重试', auth_rejected:'账号未通过', portal_not_found:'未发现认证网关', portal_not_ready:'等待认证网关', no_account:'请选择账号', stopped:'尚未运行', login_accepted:'登录已受理', blocked:'请检查上游', request_failed:'认证结果待确认' };
const samples = new Map();
const css = `.bjut-workbench{--bj-bg:#eef2f8;--bj-card:#fff;--bj-text:#182235;--bj-muted:#697a94;--bj-border:#dce3ed;--bj-blue:#3478f6;--bj-ok:#18b991;--bj-error:#ee6a75;color:var(--bj-text);font-size:14px;padding:8px 4px 20px}.bjut-workbench h2{font-size:26px;font-weight:700;margin:8px 0 16px}.bjut-workbench h3{font-size:17px;margin:0 0 12px}.bjut-workbench p{color:var(--bj-muted);margin:8px 0;overflow-wrap:anywhere}.bjut-workbench .bj-card{border:1px solid var(--bj-border);background:var(--bj-card);border-radius:18px;padding:20px;box-shadow:0 6px 18px #172b4d0c;min-width:0;margin:14px 0}.bjut-workbench .bj-header,.bjut-workbench .bj-actions{display:flex;gap:12px;align-items:center;justify-content:space-between;flex-wrap:wrap}.bjut-workbench .bj-header h2{margin:0}.bjut-workbench .bj-ports{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;padding:12px 0}.bjut-workbench .bj-port{border:1px solid var(--bj-border);border-radius:16px;background:var(--bj-card);min-width:0;text-align:center;overflow:hidden;box-shadow:0 5px 14px #172b4d0b}.bjut-workbench .bj-port-title{font-size:17px;font-weight:700;background:var(--bj-bg);padding:12px 8px}.bjut-workbench .bj-port-body{padding:16px 12px}.bjut-workbench .bj-port-icon{font-size:32px;line-height:1.2;color:var(--bj-blue);margin-bottom:8px}.bjut-workbench .bj-speed{font-weight:600;color:var(--bj-muted)}.bjut-workbench .bj-paths{display:flex;gap:4px;margin:14px 0 12px}.bjut-workbench .bj-path{flex:1;padding:4px;border-radius:8px;background:#92a2b526;color:var(--bj-muted);font-size:12px}.bjut-workbench .bj-path.ok{background:#18b99122;color:var(--bj-ok)}.bjut-workbench .bj-path.fail{background:#ee6a7522;color:var(--bj-error)}.bjut-workbench .bj-port-state{font-weight:600;min-height:40px;display:grid;place-items:center}.bjut-workbench .bj-port-meta{font-size:12px;color:var(--bj-muted);overflow-wrap:anywhere;margin:8px 0}.bjut-workbench .bj-traffic{display:grid;gap:5px;font-variant-numeric:tabular-nums;text-align:left;margin-top:14px}.bjut-workbench .bj-traffic small{float:right;color:var(--bj-muted)}.bjut-workbench .bj-select{display:block;width:100%;min-width:0;height:38px;margin:12px 0 8px}.bjut-workbench .bj-login{width:100%;min-height:38px}.bjut-workbench .bj-details{margin-top:10px;text-align:left;font-size:12px}.bjut-workbench .bj-details summary{cursor:pointer;color:var(--bj-muted)}.bjut-workbench .bj-summary{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:16px}.bjut-workbench .bj-summary strong{display:block;font-size:24px;color:var(--bj-blue);margin-top:8px}.bjut-workbench .bj-log{white-space:pre-wrap;overflow-wrap:anywhere;max-height:65vh;overflow:auto;font:12px/1.8 monospace;padding:16px;border-radius:14px;background:var(--bj-bg)}.bjut-workbench .bj-billing-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px}.bjut-workbench .bj-billing-grid>.bj-card{margin:0}.bjut-workbench progress{width:100%;height:8px;accent-color:var(--bj-blue)}@media(max-width:600px){.bjut-workbench .bj-ports{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.bjut-workbench .bj-card{padding:16px}.bjut-workbench .bj-port-body{padding:14px 8px}.bjut-workbench .bj-port-title{font-size:15px}.bjut-workbench .bj-billing-grid{grid-template-columns:1fr}}@media(prefers-color-scheme:dark){.bjut-workbench{--bj-bg:#202735;--bj-card:#2b3341;--bj-text:#eef4fc;--bj-muted:#afbed1;--bj-border:#455064}}`;

function portIcon() {
 const parser = new DOMParser();
 return document.importNode(parser.parseFromString('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 3h16v13h-5v5H9v-5H4z"/><path d="M8 7v4m3-4v4m3-4v4m3-4v4M12 16v5"/></svg>', 'image/svg+xml').documentElement, true);
}

function bytes(value) {
	let n = Number(value) || 0, unit = 0;
	const units = ['B','KiB','MiB','GiB','TiB'];
	while (n >= 1024 && unit < 4) { n /= 1024; unit++; }
	return n.toFixed(unit > 1 ? 1 : 0) + ' ' + units[unit];
}
function rate(port) {
	const now = performance.now(), previous = samples.get(port.uplink);
	samples.set(port.uplink, {at:now,tx:Number(port.txBytes),rx:Number(port.rxBytes)});
	const seconds = previous ? (now - previous.at) / 1000 : 0;
	return seconds > .2 ? {tx:Math.max(0,Number(port.txBytes)-previous.tx)/seconds,rx:Math.max(0,Number(port.rxBytes)-previous.rx)/seconds} : {tx:0,rx:0};
}

return baseclass.extend({
	style: function() { return E('style', {}, css); },
	label: function(state) { return _(labels[state] || state || '等待检测'); },
	bytes: bytes,
	ports: function(data, portData, accountData, login) {
		return E('div', {'class':'bj-ports'}, (data.uplinks || []).map(function(item) {
			const port = (portData.ports || []).find(function(p) { return p.uplink === item.id; }) || {};
			const speed = Number(port.speedMbps), rates = rate(Object.assign({uplink:item.id},port));
			const selector = E('select', {'class':'cbi-input-select bj-select','aria-label':_('账号')}, [E('option',{value:''},_('自动选择账号'))].concat((accountData.accounts || []).filter(function(a) { return a.hasPassword; }).map(function(a) { return E('option',{value:a.id},a.user+(a.enabled?'':_('（手动）'))); })));
			const action = E('button',{'class':'btn cbi-button-action bj-login',type:'button',click:async function() {
				action.disabled = true;
				try { const response = await login(item.id,selector.value); note.textContent = response.message || _('已开始检测'); }
				catch(error) { note.textContent = String(error.message || error); }
				finally { action.disabled = false; }
			}},_('登录'));
			const note = E('p',{'class':'bj-port-meta','role':'status'},item.checking ? item.check_message || _('正在检测…') : item.account ? _('账号')+' '+item.account : _('暂无认证账号'));
			function family(name,value) { return E('span',{'class':'bj-path '+(value==='reachable'?'ok':value==='unreachable'?'fail':'')},(value==='reachable'?'✓ ':value==='unreachable'?'× ':'— ')+name); }
			return E('article',{'class':'bj-port'},[
				E('div',{'class':'bj-port-title'},item.device || port.device || item.network || item.id),
				E('div',{'class':'bj-port-body'},[
					E('div',{'class':'bj-port-icon','aria-hidden':'true'},portIcon()),
					E('div',{'class':'bj-speed'},port.linkUp===0 ? _('已断开') : speed ? (speed>=1000 ? (speed/1000)+' GbE' : speed+' Mbps') : item.transport==='wifi'?'Wi-Fi':_('有线')),
					E('div',{'class':'bj-paths'},[family('IPv4',item.internet4),family('IPv6',item.internet6)]),
					E('div',{'class':'bj-port-state'},_(labels[item.state] || item.state || '等待检测')), note,
					E('div',{'class':'bj-traffic'},[
						E('div',{},['▲ '+bytes(port.txBytes),E('small',{},bytes(rates.tx)+'/s')]),
						E('div',{},['▼ '+bytes(port.rxBytes),E('small',{},bytes(rates.rx)+'/s')])]),
					selector,action,
					E('details',{'class':'bj-details'},[E('summary',{},_('网络详情')),E('p',{},[item.network,item.network6].filter(Boolean).join(' / ')),E('p',{},'IPv4 '+(item.ipv4 || '--')),E('p',{},'IPv6 '+(item.ipv6 || '--')),E('p',{},item.message || '')])])]);
		}));
	}
});
