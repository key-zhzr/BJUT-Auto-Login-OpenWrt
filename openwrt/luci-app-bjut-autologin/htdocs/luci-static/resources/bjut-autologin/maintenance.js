'use strict';
'require baseclass';
'require ui';
'require bjut-autologin.client as client';
'require bjut-autologin.workbench as bjut';

async function show() {
 let info=null,prepared='',busy=false,closed=false;
 const description=E('p'),message=E('p',{'role':'status'}),progress=E('progress',{max:100,value:0,hidden:true}),buttons=E('div',{'class':'bj-actions'}),backups=E('div');
 const root=E('div',{'class':'bjut-workbench'},[bjut.style(),description,buttons,progress,message,backups]);
 function button(label,fn){return E('button',{type:'button','class':'btn',click:fn},_(label));}
 const controls=[];
 function update(){controls.forEach(function(item){item.button.disabled=busy || item.action==='upgrade' && !prepared || item.action==='rollback' && !(info && info.platform.rollback);});}
 async function read(){
  info=await client.call('maintenance_info');if(closed)return;
  description.textContent=info.platform.version+' · '+info.platform.target+' · '+info.platform.arch+' · '+info.platform.format.toUpperCase();
  backups.replaceChildren.apply(backups,(info.backups || []).slice().reverse().map(function(item){return E('div',{'class':'bj-card bj-header'},[E('span',{},item.createdAt+' · '+item.version),button('恢复配置',function(){void run('restore',item.id);})]);}));update();
 }
 async function wait(ticket){
  const deadline=Date.now()+900000;
  while(!closed && Date.now()<deadline){
   const result=await client.call('maintenance_poll',{ticket:ticket});if(closed)return;
   message.textContent=(result.release?result.release+' · ':'')+result.message;progress.hidden=result.state!=='loading';progress.value=result.percent || 0;
   if(result.state==='error')throw new Error(result.message);
   if(result.state==='prepared'){prepared=ticket;return;}
   if(result.state==='ready')return;
   await new Promise(function(resolve){window.setTimeout(resolve,1500);});
  }
  if(!closed)throw new Error(_('等待超时，请重新读取路由器状态'));
 }
 async function run(action,backup){
  if(busy)return;
  if(['upgrade','restore','rollback'].includes(action) && !window.confirm(_('此操作会先备份当前配置，并可能短暂断开路由协作。继续？')))return;
  busy=true;update();
  try{const result=await client.call('maintenance_start',{action:action,backup:backup || '',prepared:prepared});if(!result.ticket)throw new Error(result.message || _('无法开始维护'));await wait(result.ticket);if(!closed)await read();}
  catch(error){if(!closed)message.textContent=String(error.message || error);}
  finally{busy=false;update();}
 }
 for(const [action,label] of [['backup','备份配置'],['check','检查更新'],['prepare','准备安装包'],['upgrade','安装更新'],['rollback','回退版本']]){
  const control=button(label,function(){void run(action);});controls.push({action:action,button:control});buttons.append(control);
 }
 ui.showModal(_('路由器备份与更新'),[root,E('div',{'class':'right'},[button('关闭',function(){closed=true;ui.hideModal();})])]);
 try{await read();if(info.platform.lastJob){const last=await client.call('maintenance_poll',{ticket:info.platform.lastJob});message.textContent=last.message || '';if(last.state==='prepared')prepared=info.platform.lastJob;else if(last.state==='loading'){busy=true;update();await wait(info.platform.lastJob);busy=false;}update();}}
 catch(error){message.textContent=String(error.message || error);}
}
return baseclass.extend({show:show});
