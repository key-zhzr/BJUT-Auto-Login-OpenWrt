'use strict';
'require baseclass';
'require rpc';
'require bjut-autologin.client as client';
const begin=function(uplink,account,owner,kind,start_date,end_date,year,page){return client.call('billing_records',{uplink:uplink,account:account,owner:owner,kind:kind,start_date:start_date,end_date:end_date,year:year,page:page});};
const result=function(ticket,owner){return client.call('billing_poll',{ticket:ticket,owner:owner});};
const captcha=function(ticket,owner,code,refresh){return client.call('billing_captcha',{ticket:ticket,owner:owner,code:code,refresh:refresh});};
const kinds=[['usage','上网明细'],['monthly','月账单'],['payments','缴费记录'],['operations','操作记录'],['stopLogs','停机记录'],['reopenLogs','复机记录'],['packageLogs','套餐变更']];
const labels={accessMethod:'接入方式',loginTime:'登录时间',logoutTime:'下线时间',time:'在线时长（分钟）',flow:'流量（MB）',costMoney:'费用（元）',internetUpFlow:'互联网上传',internetDownFlow:'互联网下载',chinanetUpFlow:'校园网上传',chinanetDownFlow:'校园网下载',userIp:'IPv4',userIp1:'IPv6',macAddress:'MAC',nasIp:'网关',nasPort:'端口',startAt:'开始日期',endAt:'结束日期',package:'套餐',baseFee:'基本费（元）',usageFee:'用量费（元）',durationMinutes:'在线分钟',flowMb:'流量（MB）',billedAt:'结算时间',paidAt:'缴费时间',type:'类型',amount:'金额（元）',terminal:'终端',note:'备注',operatedAt:'操作时间',description:'说明',unused:'其他',fldoperatedate:'操作日期',fldoperateid:'操作',fldadminid:'操作员',fldmemo:'备注',fldnewvalue:'内容',fldchangedate:'变更日期',fldexcutedate:'生效日期',flddefaultname1:'原套餐',flddefaultname2:'新套餐',fldstate:'状态',fldstatedate:'状态日期',fldextend:'备注'};
return baseclass.extend({
 render:function(getTargets){
  let jobs=[],busy=false,polling=false,generation=0;
  function button(text,action,className){return E('button',{'class':className || 'btn',type:'button',click:action},_(text));}
  function field(text,input){return E('label',{},[E('span',{},_(text)),input]);}
  const kind=E('select',{'class':'cbi-input-select'},kinds.map(function(item){return E('option',{value:item[0]},_(item[1]));}));
  const now=new Date(),date=function(d){return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');};
  const start=E('input',{'class':'cbi-input-text',type:'date',value:date(new Date(now.getFullYear(),now.getMonth(),1))}),end=E('input',{'class':'cbi-input-text',type:'date',value:date(now)}),year=E('input',{'class':'cbi-input-text',type:'number',min:2000,max:2199,value:now.getFullYear()});
  const message=E('p',{'class':'bj-record-message','role':'status'},_('选择类型和日期后查询。'));
  const rows=E('div',{'class':'bj-record-results'});
  const query=button('查询',function(){void load();},'btn bj-primary');
  const range=E('div',{'class':'bj-record-range'},[field('开始日期',start),E('span',{'class':'bj-range-sep','aria-hidden':'true'},_('至')),field('结束日期',end)]);
  const yearField=field('年份',year);
  const controls=E('div',{'class':'bj-record-controls'},[field('类型',kind),range,yearField,query]);
  const heading=E('div',{'class':'bj-record-heading'},[E('div',{},[E('h3',{},_('账单与办理记录')),message])]);
  function fields(){const dates=['usage','payments','operations'].includes(kind.value);range.hidden=!dates;yearField.hidden=kind.value!=='monthly';}
  function clear(){if(busy)return;jobs=[];rows.replaceChildren();message.textContent=_('选择类型和日期后查询。');}
  kind.addEventListener('change',function(){fields();clear();});[start,end,year].forEach(function(input){input.addEventListener('change',clear);});fields();
  function state(){busy=jobs.some(function(job){return job.running;});[query,kind,start,end,year].forEach(function(input){input.disabled=busy;});message.textContent=busy?_('正在查询用量与账单…'):_('查询已完成');}
  async function load(target,page){
   if(busy)return;page=page || 1;const dates=['usage','payments','operations'].includes(kind.value);
   if(dates && (!start.value || !end.value || start.value>end.value)){message.textContent=_('请检查日期范围。');return;}
   if(kind.value==='monthly' && (!/^\d{4}$/.test(year.value) || +year.value<2000 || +year.value>2199)){message.textContent=_('请检查年份。');return;}
   const targets=target?[target]:getTargets();if(!targets.length){message.textContent=_('请先查询计费账号。');return;}
   const current=++generation;const previous=target?jobs.filter(function(job){return job.target.uplink!==target.uplink;}):[];
   jobs=previous.concat(targets.map(function(item){return {target:item,ticket:'',running:true,item:{state:'loading',message:_('正在准备查询'),percent:2},card:E('article',{'class':'bj-record-card bj-enter'})};}));rows.replaceChildren.apply(rows,jobs.map(function(job){return job.card;}));state();draw();
   await Promise.all(jobs.filter(function(job){return job.running;}).map(async function(job){try{const response=await begin(job.target.uplink,job.target.account,L.env.sessionid,kind.value,dates?start.value:'',dates?end.value:'',kind.value==='monthly'?year.value:'',String(page));if(current!==generation)return;if(!response.ticket)throw new Error(response.message || _('查询未开始'));job.ticket=response.ticket;}catch(error){if(current===generation){job.running=false;job.item={state:'error',message:String(error.message || error)};}}}));if(current===generation){state();draw();}
  }
  function exportPage(item){
   const quote=function(value){value=String(value);if(/^[=+\-@\t\r]/.test(value))value="'"+value;return '"'+value.replace(/"/g,'""')+'"';};
   const content=[(item.columns || []).map(function(key){return labels[key] || _('其他');})].concat(item.rows || []).map(function(row){return row.map(quote).join(',');}).join('\r\n');
   const url=URL.createObjectURL(new Blob(['\ufeff',content],{type:'text/csv;charset=utf-8'})),a=E('a',{href:url,download:'计费记录-'+item.kind+'-第'+item.page+'页.csv'});a.click();window.setTimeout(function(){URL.revokeObjectURL(url);},1000);
  }
  function showCaptcha(job){const input=E('input',{'class':'cbi-input-text',type:'text',maxlength:12,autocomplete:'off',placeholder:_('验证码')}),image=E('img',{alt:_('计费验证码')});if(/^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=]+$/.test(job.item.image || ''))image.src=job.item.image;
   async function answer(refresh){if(job.running || (!refresh && !input.value.trim()))return;job.running=true;state();try{const response=await captcha(job.ticket,L.env.sessionid,input.value.trim(),refresh);if(response.state==='error')throw new Error(response.message);job.item={state:'loading',message:_('正在核对验证码'),percent:40};draw();}catch(error){job.running=false;message.textContent=String(error.message || error);state();}}
   job.card.append(image,input,E('div',{'class':'bj-actions'},[button('换一张',function(){void answer(true);}),button('继续',function(){void answer(false);})]));
  }
  function draw(){const seen=new Set();jobs.forEach(function(job){const item=job.item;if(item.state==='ready' && item.account && seen.has(item.account)){job.card.hidden=true;return;}if(item.state==='ready' && item.account)seen.add(item.account);job.card.hidden=false;const stamp=JSON.stringify(item);if(job.card.dataset.result===stamp)return;job.card.dataset.result=stamp;job.card.replaceChildren(E('h3',{},item.account?_('账号')+' '+item.account:job.target.title),E('p',{'class':'bj-billing-status'},item.message || _('等待查询')));
   if(item.state==='loading')job.card.append(E('progress',{max:100,value:item.percent || 2}));if(item.state==='captcha')showCaptcha(job);
   if(item.state==='ready'){if(item.summary && Object.keys(item.summary).length)job.card.append(E('p',{'class':'bj-billing-status'},Object.entries(item.summary).map(function(pair){return pair[0]+'：'+pair[1];}).join(' · ')));const columns=item.columns || [],body=(item.rows || []).map(function(row){return E('tr',{},columns.map(function(key,i){return E('td',{},String(row[i] ?? '--'));}));});job.card.append(E('div',{'class':'bj-table-scroll'},E('table',{'class':'bj-table'},[E('thead',{},E('tr',{},columns.map(function(key){return E('th',{},_(labels[key] || '其他'));}))),E('tbody',{},body)])));if(!body.length)job.card.append(E('p',{},_('暂无记录。')));
    const page=item.page || 1,pages=Math.max(1,Math.ceil((item.total || 0)/100)),prev=button('上一页',function(){void load(job.target,page-1);}),next=button('下一页',function(){void load(job.target,page+1);});prev.disabled=page<=1;next.disabled=page>=pages;
    const pager=E('div',{'class':'bj-record-pager'},[E('span',{},(item.total || 0)+' '+_('条')+' · '+page+' / '+pages),prev,next]);
    job.card.append(E('div',{'class':'bj-record-footer'},[pager,button('导出本页',function(){exportPage(item);})]));}
  });}
  const root=E('section',{'class':'bj-card bj-record-panel bj-enter'});
  client.watch(root,async function(){if(polling || !jobs.some(function(job){return job.running && job.ticket;}))return;polling=true;const current=generation;try{await Promise.all(jobs.filter(function(job){return job.running && job.ticket;}).map(async function(job){try{const response=await result(job.ticket,L.env.sessionid);if(current!==generation)return;const item=response.result || response;if(item.state==='ready' && job.target.expectedAccount && item.account!==job.target.expectedAccount)throw new Error(_('计费账号已变化，请重新查询概览。'));job.item=item;job.running=job.item.state==='loading';}catch(error){if(current===generation){job.running=false;job.item={state:'error',message:String(error.message || error)};}}}));if(current===generation){state();draw();}}finally{polling=false;}},1);
  root.append(heading,controls,rows);return root;
 }
});
