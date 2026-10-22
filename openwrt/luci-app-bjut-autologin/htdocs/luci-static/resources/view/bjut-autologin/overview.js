'use strict';
'require view';
'require bjut-autologin.client as client';
'require bjut-autologin.workbench as bjut';
return view.extend({
 handleSave:null,handleSaveApply:null,handleReset:null,
 load:function(){return client.call('dashboard');},
 render:function(data){
  const summary=E('p'),message=E('p',{'role':'status'});let checking=false,watcher,last=data;
  function action(name){return function(uplink,account){return client.call(name,{uplink:uplink,account:account || ''});};}
  const grid=bjut.portGrid({login:action('login'),logout:action('logout'),switchAccount:action('switch_account'),changed:function(){return watcher.refresh();}});
  function draw(next){last=next;const list=next.status.uplinks || [];checking=list.some(function(item){return item.checking;});summary.textContent=_('已连接上游')+' '+list.filter(function(item){return item.state==='online' || item.state==='authenticated_limited';}).length+' / '+list.length;grid.render(next.status,next.ports,next.accounts);}
  const root=E('div',{'class':'bjut-workbench'},[bjut.style(),summary,message,E('section',{'class':'bj-card'},[E('h3',{},_('端口状态')),grid.element])]);
  draw(data);watcher=client.watch(root,async function(){try{draw(await client.call('dashboard'));message.textContent='';}catch(error){draw(Object.assign({},last,{status:Object.assign({},last.status,{uplinks:(last.status.uplinks || []).map(function(item){return Object.assign({},item,{stale:1});})})}));message.textContent=_('状态读取失败，将自动重试：')+String(error.message || error);}},function(){return checking?1:2;});
  return bjut.disclosures(root);
 }
});
