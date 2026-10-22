'use strict';
'require view';
'require rpc';
'require bjut-autologin.client as client';
'require bjut-autologin.workbench as bjut';
const status=function(){return client.call('status',{});};
return view.extend({
	handleSave:null,handleSaveApply:null,handleReset:null,
	load:function() { return status(); },
	render:function(data) {
		let latest=data;
		const content = E('div'), message = E('p',{},_('参考各条上游最近一次检测结果。'));
		function advice(item){
			if(item.stale)return _('检测结果已过期，请核对路由器服务。');
			if(item.route4==='failed' || item.route6==='failed' || item.route4==='missing_default')return _('上游出口未就绪，请检查接口网关和策略路由。');
			if(item.state==='auth_rejected')return _('请核对密码、余额及账号状态。');
			if(item.state==='account_busy')return _('账号已达到并发上限，可选择备用账号。');
			if(item.state==='waiting_interface')return _('上游未取得地址，请检查网线或 Wi-Fi 连接。');
			if(item.session==='online' && item.internet4!=='reachable' && item.internet6!=='reachable')return _('认证会话有效，请检查外网路由、DNS 和探测目标。');
			if(item.internet4==='reachable' && item.internet6==='unreachable')return _('IPv4 可用，请检查 IPv6 地址、默认路由及双栈认证。');
			return item.state==='online'?_('此上游连接正常。'):_('请结合其他上游和 App 本机诊断核对。');
		}
		function draw(next) {
			latest=next;
			const family = function(value) { return value==='reachable'?_('通过'):value==='unreachable'?_('未通过'):value==='not_configured'?_('未取得地址'):_('待检测'); };
			const route = function(value) { return {managed:_('固定出口'),kernel:_('系统路由'),missing_default:_('缺少默认路由'),failed:_('出口未就绪'),not_configured:_('未取得地址')}[value] || _('待检查'); };
			content.replaceChildren.apply(content,(next.uplinks || []).map(function(item) {
				return E('article',{'class':'bj-card bj-enter'},[E('h3',{},[item.device,item.network].filter(Boolean).join(' · ') || item.id),E('strong',{},item.stale?_('数据已过期'):bjut.label(item.state)),E('p',{},'IPv4 '+family(item.internet4)+' · IPv6 '+family(item.internet6)),E('p',{},'IPv4 '+route(item.route4)+' · IPv6 '+route(item.route6)),E('p',{},item.session==='online'?_('认证会话：已认证'):item.session==='offline'?_('认证会话：未认证'):_('认证会话：待确认')),E('p',{},advice(item)),E('p',{},item.updated_at?new Date(item.updated_at*1000).toLocaleString():_('尚无检测结果'))]);
			}));
		}
		async function refresh() { try { draw(await status());message.textContent=_('已更新各上游检测结果。'); } catch(error) { draw(Object.assign({},latest,{uplinks:(latest.uplinks || []).map(function(item){return Object.assign({},item,{stale:1});})}));message.textContent=_('暂时无法连接路由服务，显示上次结果。'); } }
		function exportReport(){
			const report={apiVersion:1,generatedAt:new Date().toISOString(),version:latest.version,uplinks:(latest.uplinks || []).map(function(item){
				const row={};for(const key of ['id','device','network','state','session','internet4','internet6','route4','route6','updated_at','age_seconds','stale'])row[key]=item[key];row.advice=advice(item);return row;
			})};
			const url=URL.createObjectURL(new Blob([JSON.stringify(report,null,2)],{type:'application/json'}));const a=E('a',{href:url,download:'BJUT-AL-路由诊断.json'});a.click();window.setTimeout(function(){URL.revokeObjectURL(url);},1000);
		}
		draw(data);
		const root=E('div',{'class':'bjut-workbench'},[bjut.style(),E('div',{'class':'bj-actions'},[message,E('button',{'class':'btn',type:'button',click:refresh},_('刷新')),E('button',{'class':'btn',type:'button',click:exportReport},_('导出诊断包'))]),content]);
        client.watch(root,refresh,2);return root;
	}
});
