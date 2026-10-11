'use strict';
'require view';
'require rpc';
'require poll';
'require bjut-autologin.workbench as bjut';
const logs = rpc.declare({object:'bjut-autologin',method:'logs',expect:{}});
return view.extend({
	handleSave:null,handleSaveApply:null,handleReset:null,
	load:function() { return logs(); },
	render:function(data) {
		const content = E('pre',{'class':'bj-log'},data.text || _('暂无日志。'));
		let busy = false;
		async function refresh() {
			if (busy) return; busy = true;
			try { const next = await logs(); content.textContent = next.text || _('暂无日志。'); }
			catch(error) { content.textContent = String(error.message || error); }
			finally { busy = false; }
		}
		poll.add(refresh,5);
		return E('div',{'class':'bjut-workbench'},[bjut.style(),E('header',{'class':'bj-header'},[E('h2',{},_('运行日志')),E('button',{'class':'btn',type:'button',click:refresh},_('刷新'))]),E('section',{'class':'bj-card'},content)]);
	}
});
