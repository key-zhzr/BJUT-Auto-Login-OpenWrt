'use strict';
'require baseclass';
'require bjut-autologin.client as client';
'require bjut-autologin.usage-model as usage';
'require bjut-autologin.workbench as bjut';

return baseclass.extend({render:function() {
 const body=E('div'),status=E('p',{'class':'bj-billing-subtitle','role':'status'},_('计费系统数据 · 每分钟更新 · 已用流量为本次在线会话累计'));
 let data={accounts:[],history:[]},stamp='',accountStamp='';
 const range=E('select',{'data-traffic-filter':'range',change:draw},[7,30,90].map(function(days){return E('option',{value:String(days),selected:days===30},days+' '+_('天'));}));
 const period=E('select',{'data-traffic-filter':'period',change:draw},[E('option',{value:'day'},_('按天')),E('option',{value:'month'},_('按月'))]);
 const account=E('select',{'data-traffic-filter':'account',change:draw},[E('option',{value:''},_('全部账号'))]);
 function selectedRows() {
  const now=Date.now()+8*3600000,today=new Date(now).toISOString().slice(0,10);
  const oldest=new Date(now-(Number(range.value)-1)*86400000).toISOString().slice(0,10);
  return (data.history || []).filter(function(row){return row.day>=oldest && row.day<=today && Number.isFinite(row.usedMb) && row.usedMb>=0 && (!account.value || row.account===account.value);});
 }
 const exportButton=E('button',{type:'button','class':'btn cbi-button',click:function() {
  const link=E('a',{download:'device-usage.csv',href:URL.createObjectURL(new Blob([usage.usageCsv(selectedRows())],{type:'text/csv;charset=utf-8'}))});
  link.click();setTimeout(function(){URL.revokeObjectURL(link.href);},1000);
 }},_('导出 CSV'));
 const controls=E('div',{'class':'bj-record-controls'},[
  E('label',{},[_('日期范围'),range]),E('label',{},[_('统计方式'),period]),E('label',{},[_('账号'),account]),exportButton
 ]);
 const root=E('section',{'class':'bj-card bj-device-usage'},[
  E('style',{},'.bj-device-usage .bj-usage-bar{display:grid;grid-template-columns:70px minmax(0,1fr) 90px;gap:10px;align-items:center;margin:8px 0;font-size:12px}.bj-device-usage .bj-usage-bar i{height:8px;border-radius:6px;background:var(--bj-blue);opacity:.7}.bj-device-usage .bj-usage-bar strong{text-align:right;white-space:nowrap}'),
  E('h3',{},_('设备流量')),status,controls,body
 ]);
 function format(value) {
  const n=Number(value);return value!=='' && value!=null && Number.isFinite(n)?usage.flowLabel(n):'--';
 }
 function draw() {
  bjut.resize(body,function() {
   body.replaceChildren();
   (data.accounts || []).filter(function(item){return !account.value || item.account===account.value;}).forEach(function(item) {
    const card=E('section',{'class':'bj-upstream-card'},[
     E('h4',{},item.account),
     E('p',{},item.updatedAt?_('更新于')+' '+new Date(item.updatedAt*1000).toLocaleTimeString()+(item.error || Date.now()/1000-item.updatedAt>180?' · '+_('上次成功数据'):''):_('等待查询'))
    ]);
    if(item.error)card.append(E('p',{},item.error));
    (item.devices || []).forEach(function(device) {
     card.append(E('div',{'class':'bj-bill-row'},[
      E('span',{},(device.mac || device.ip || _('在线设备'))+' · '+(device.ip || device.ipv6 || '')),E('strong',{},format(device.usedFlowMb))
     ]));
    });
    if(item.updatedAt && !item.error && !(item.devices || []).length)card.append(E('p',{},_('当前没有在线设备')));
    const prediction=usage.forecastUsage((data.history || []).filter(function(row){return row.account===item.account;}),item.remainingFlow || '');
    if(prediction)card.append(E('p',{},_('按近7天采样估算，月底前约需')+' '+usage.flowLabel(prediction.projectedMb)+(prediction.shortfallMb>0?' · '+_('可能超出余量')+' '+usage.flowLabel(prediction.shortfallMb):'')));
    body.append(card);
   });
   if(!(data.accounts || []).length)body.append(E('p',{},_('添加计费账号后自动更新。')));
   const rows=selectedRows(),totals=new Map();
   rows.forEach(function(row){const label=period.value==='month'?row.day.slice(0,7):row.day;totals.set(label,(totals.get(label)||0)+row.usedMb);});
   const chart=E('div',{'class':'bj-traffic-history'},[E('h4',{},period.value==='month'?_('每月采样新增流量'):_('每日采样新增流量'))]);
   const max=Math.max(1,...totals.values());
   Array.from(totals).sort(function(a,b){return a[0].localeCompare(b[0]);}).forEach(function(row) {
    chart.append(E('div',{'class':'bj-usage-bar'},[
     E('span',{},period.value==='month'?row[0]:row[0].slice(5)),E('i',{'aria-hidden':'true',style:'width:'+(row[1]/max*100)+'%'}),E('strong',{},usage.flowLabel(row[1]))
    ]));
   });
   if(!rows.length)chart.append(E('p',{},_('所选范围暂无连续采样记录。')));
   chart.append(E('p',{},_('采样新增流量')+' '+usage.flowLabel(rows.reduce(function(sum,row){return sum+row.usedMb;},0))),E('p',{},_('仅累计连续采样区间；历史每15分钟保存，正常停止服务时立即保存。')));
   body.append(chart);
  });
 }
 client.watch(root,async function() {
  try {
   const next=await client.call('traffic'),nextStamp=JSON.stringify(next);
   status.textContent=_('计费系统数据 · 每分钟更新 · 已用流量为本次在线会话累计');
   if(nextStamp===stamp)return;
   stamp=nextStamp;data=next;
   const choices=Array.from(new Set((data.accounts || []).map(function(item){return item.account;}).concat((data.history || []).map(function(row){return row.account;})))).sort();
   const nextAccounts=JSON.stringify(choices);
   if(nextAccounts!==accountStamp) {
    const selected=account.value;accountStamp=nextAccounts;
    account.replaceChildren(E('option',{value:''},_('全部账号')),...choices.map(function(value){return E('option',{value:value},value);}));
    account.value=choices.includes(selected)?selected:'';
   }
   draw();
  } catch(error) {status.textContent=_('设备流量暂未更新，将自动重试。');}
 },5);
 return root;
}});
