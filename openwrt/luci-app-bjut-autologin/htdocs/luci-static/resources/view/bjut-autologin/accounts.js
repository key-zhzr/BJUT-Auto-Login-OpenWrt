'use strict';
'require view';
'require rpc';
'require bjut-autologin.workbench as bjut';
const accounts = rpc.declare({object:'bjut-autologin',method:'accounts',expect:{}});
const change = rpc.declare({object:'bjut-autologin',method:'account_set',params:['account','enabled'],expect:{}});
return view.extend({
	handleSave:null,handleSaveApply:null,handleReset:null,
	load:function() { return accounts(); },
	render:function(data) {
		const rows = E('div'), message = E('p',{'role':'status'});
		function draw(items) {
			rows.replaceChildren.apply(rows,(items.accounts || []).map(function(item) {
				const action = E('button',{'class':'btn',type:'button',click:async function() {
					action.disabled = true;
					try { const result = await change(item.id,item.enabled?'0':'1'); message.textContent = result.message; if (result.state==='ready') draw(await accounts()); }
					catch(error) { message.textContent = String(error.message || error); }
					finally { action.disabled = false; }
				}},item.enabled?_('停用自动登录'):_('启用自动登录'));
				return E('article',{'class':'bj-card bj-header'},[E('div',{},[E('h3',{},item.user),E('p',{},item.enabled?_('参与自动登录'):_('仅手动使用'))]),action]);
			}));
		}
		draw(data);
		return E('div',{'class':'bjut-workbench'},[bjut.style(),E('header',{'class':'bj-header'},[E('h2',{},_('账号管理')),E('a',{'class':'btn',href:L.url('admin/network/bjut-autologin/config')},_('编辑账号'))]),message,rows]);
	}
});
