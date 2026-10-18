'use strict';
'require view';
'require rpc';
'require bjut-autologin.client as client';
'require bjut-autologin.workbench as bjut';
const logs=function(){return client.call('logs',{});};
return view.extend({
	handleSave:null,handleSaveApply:null,handleReset:null,
	load:function() { return logs(); },
	render:function(data) {
		const content = E('pre',{'class':'bj-log'},data.text || _('暂无日志。'));
		let busy = false;
		async function refresh() {
			if (busy) return; busy = true;
			try { const next = await logs(); const text=next.text || _('暂无日志。');if(content.textContent!==text){const follow=content.scrollTop+content.clientHeight>=content.scrollHeight-20,top=content.scrollTop;content.textContent=text;content.scrollTop=follow?content.scrollHeight:top;} }
			catch(error) { content.textContent = String(error.message || error); }
			finally { busy = false; }
		}
		const root=E('div',{'class':'bjut-workbench'},[bjut.style(),E('div',{'class':'bj-actions'},[E('button',{'class':'btn',type:'button',click:refresh},_('刷新'))]),E('section',{'class':'bj-card'},content)]);
        client.watch(root,refresh,2);
		return root;
	}
});
