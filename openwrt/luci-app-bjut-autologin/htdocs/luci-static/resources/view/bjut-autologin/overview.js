'use strict';
'require view';
'require rpc';
'require poll';
'require bjut-autologin.workbench as bjut';

const status = rpc.declare({object:'bjut-autologin',method:'status',expect:{}});
const ports = rpc.declare({object:'bjut-autologin',method:'ports',expect:{}});
const accounts = rpc.declare({object:'bjut-autologin',method:'accounts',expect:{}});
const login = rpc.declare({object:'bjut-autologin',method:'login',params:['uplink','account'],expect:{}});

return view.extend({
	handleSave:null,handleSaveApply:null,handleReset:null,
	load:function() { return Promise.all([status(),ports(),accounts()]); },
	render:function(data) {
		const cards = E('div'), summary = E('p'), message = E('p',{'role':'status'});
		let previous = '', busy = false;
		function draw(next) {
			const stamp = JSON.stringify(next);
			const up = (next[0].uplinks || []).filter(function(item) { return item.state==='online' || item.state==='authenticated_limited'; }).length;
			summary.textContent = _('已连接上游')+' '+up+' / '+(next[0].uplinks || []).length;
			if (stamp !== previous && !cards.contains(document.activeElement)) {
				cards.replaceChildren(bjut.ports(next[0],next[1],next[2],login)); previous = stamp;
			}
		}
		async function refresh() {
			if (busy) return; busy = true;
			try { draw(await Promise.all([status(),ports(),accounts()])); message.textContent = ''; }
			catch(error) { message.textContent = _('状态读取失败：')+String(error.message || error); }
			finally { busy = false; }
		}
		draw(data); poll.add(refresh,2);
		return E('div',{'class':'bjut-workbench'},[bjut.style(),E('div',{'class':'bj-header'},[E('h2',{},_('控制台')),E('button',{'class':'btn',type:'button',click:refresh},_('刷新'))]),summary,message,E('section',{'class':'bj-card'},[E('h3',{},_('端口状态')),cards])]);
	}
});
