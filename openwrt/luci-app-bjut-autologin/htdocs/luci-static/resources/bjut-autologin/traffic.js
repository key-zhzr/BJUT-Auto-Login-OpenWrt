'use strict';
'require baseclass';
'require bjut-autologin.client as client';
'require bjut-autologin.usage-model as usage';
'require bjut-autologin.workbench as bjut';

return baseclass.extend({render:function() {
 const root=E('section',{'class':'bj-card bj-device-usage'});
 let watcher;
 const chart=new usage.UsageChart(root,{
  title:_('流量趋势'),localLabel:_('仅路由器上游'),resize:bjut.resize,
  configure:async function(enabled,scope){await client.call('save_settings',{traffic_monitor:enabled?'1':'0',traffic_scope:scope},15000);await watcher.refresh();}
 });
 // The shared renderer owns the content; its stylesheet remains outside it.
 root.prepend(E('link',{rel:'stylesheet',href:L.resource('bjut-autologin/usage-chart.css')}));
 watcher=client.watch(root,async function(){
  try{chart.update(await client.call('traffic'));}
  catch(error){chart.showError(_('流量统计暂未更新，将自动重试。'));}
 },5,function(){chart.destroy();});
 return root;
}});
