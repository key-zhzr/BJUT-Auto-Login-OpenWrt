'use strict';
'require baseclass';
'require ui';
'require bjut-autologin.client as client';
'require bjut-autologin.usage-model as usage';
'require bjut-autologin.workbench as bjut';

return baseclass.extend({render:function() {
 const root=E('section',{'class':'bj-card bj-device-usage'});
 let watcher;
 const chart=new usage.UsageChart(root,{
  title:_('流量趋势'),localLabel:_('仅路由器上游'),resize:bjut.resize,
  confirm:function(enabled){return new Promise(function(resolve){let settled=false;const finish=function(accepted){if(settled)return;settled=true;document.removeEventListener('keydown',escape,true);ui.hideModal();resolve(accepted);},escape=function(event){if(event.key==='Escape'){event.preventDefault();event.stopPropagation();finish(false);}};document.addEventListener('keydown',escape,true);ui.showModal(enabled?_('开启流量统计'):_('暂停流量统计'),[E('p',{},enabled?_('按设置中的统计范围记录设备下载量。是否开启？'):_('暂停采集，已有历史会保留。是否继续？')),E('div',{'class':'right'},[E('button',{'class':'btn',click:function(){finish(false);}},_('取消')),E('button',{'class':'btn cbi-button-positive',click:function(){finish(true);}},enabled?_('开启统计'):_('暂停统计'))])]);});},
  windowChanged:function(){if(watcher)void watcher.refresh();},
  configure:async function(enabled){await client.call('save_settings',{traffic_monitor:enabled?'1':'0'},15000);await watcher.refresh();}
 });
 // The shared renderer owns the content; its stylesheet remains outside it.
 root.prepend(E('link',{rel:'stylesheet',href:L.resource('bjut-autologin/usage-chart.css')}));
 watcher=client.watch(root,async function(){
  try{chart.update(await client.call('traffic',chart.query()));}
  catch(error){chart.showError(_('流量统计暂未更新，将自动重试。'));}
 },5,function(){chart.destroy();});
 return root;
}});
