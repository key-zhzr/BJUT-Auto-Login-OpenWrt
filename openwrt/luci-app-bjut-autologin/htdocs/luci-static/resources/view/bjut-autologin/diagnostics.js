'use strict';
'require view';
'require rpc';
'require bjut-autologin.workbench as bjut';
const status = rpc.declare({object:'bjut-autologin',method:'status',expect:{}});
return view.extend({
	handleSave:null,handleSaveApply:null,handleReset:null,
	load:function() { return status(); },
	render:function(data) {
		const content = E('div'), message = E('p',{},_('参考各条上游最近一次检测结果。'));
		function draw(next) {
			const family = function(value) { return value==='reachable'?_('通过'):value==='unreachable'?_('未通过'):value==='not_configured'?_('未取得地址'):_('待检测'); };
			const route = function(value) { return {managed:_('固定出口'),kernel:_('系统路由'),missing_default:_('缺少默认路由'),failed:_('出口未就绪'),not_configured:_('未取得地址')}[value] || _('待检查'); };
			content.replaceChildren.apply(content,(next.uplinks || []).map(function(item) {
				return E('article',{'class':'bj-card'},[E('h3',{},[item.device,item.network].filter(Boolean).join(' · ') || item.id),E('strong',{},bjut.label(item.state)),E('p',{},'IPv4 '+family(item.internet4)+' · IPv6 '+family(item.internet6)),E('p',{},'IPv4 '+route(item.route4)+' · IPv6 '+route(item.route6)),E('p',{},item.message || ''),E('p',{},item.updated_at?new Date(item.updated_at*1000).toLocaleString():_('尚无检测结果'))]);
			}));
		}
		async function refresh() { try { draw(await status()); } catch(error) { message.textContent=String(error.message || error); } }
		draw(data);
		return E('div',{'class':'bjut-workbench'},[bjut.style(),E('div',{'class':'bj-header'},[E('h2',{},_('网络诊断')),E('button',{'class':'btn',type:'button',click:refresh},_('刷新'))]),message,content]);
	}
});
