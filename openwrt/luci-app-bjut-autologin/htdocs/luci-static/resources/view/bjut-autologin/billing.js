'use strict';
'require view';
'require rpc';
'require poll';
'require bjut-autologin.workbench as bjut';
'require bjut-autologin.records as records';
const status=rpc.declare({object:'bjut-autologin',method:'status',expect:{}});
const accounts=rpc.declare({object:'bjut-autologin',method:'accounts',expect:{}});
const begin=rpc.declare({object:'bjut-autologin',method:'billing_start',params:['uplink','account','owner'],expect:{}});
const result=rpc.declare({object:'bjut-autologin',method:'billing_poll',params:['ticket','owner'],expect:{}});
const captcha=rpc.declare({object:'bjut-autologin',method:'billing_captcha',params:['ticket','owner','code','refresh'],expect:{}});
return view.extend({
 handleSave:null,handleSaveApply:null,handleReset:null,
 load:function(){return Promise.all([status(),accounts()]);},
 render:function(data){
  let jobs=[],busy=false,polling=false,summaryStamp='',devicesStamp='';const uplinks=data[0].uplinks || [];
  function button(text,action){return E('button',{'class':'btn',type:'button',click:action},_(text));}
  const uplink=E('select',{'class':'cbi-input-select'},[E('option',{value:'all'},_('所有上游'))].concat(uplinks.map(function(item){return E('option',{value:item.id},[item.device,item.network].filter(Boolean).join(' · ') || item.id);}))),account=E('select',{'class':'cbi-input-select'},[E('option',{value:'current'},_('当前认证账号'))].concat((data[1].accounts || []).filter(function(item){return item.hasPassword;}).map(function(item){return E('option',{value:item.id},item.user+(item.enabled?'':_('（手动）')));}))),message=E('p',{'role':'status'}),summary=E('div',{'class':'bj-summary'}),details=E('div',{'class':'bj-billing-grid'}),devices=E('section',{'class':'bj-billing-grid bj-enter',hidden:true});
  const submit=button('刷新',function(){void refresh();});
  function targets(){const seen=new Set();return jobs.filter(function(job){const key=job.item.account || job.uplink;if(seen.has(key))return false;seen.add(key);return true;}).map(function(job){return {uplink:job.uplink,account:job.account,title:job.title};});}
  const overview=E('section',{'class':'bj-enter'},[summary,details]),recordView=records.render(targets);recordView.hidden=true;
  const sections=[overview,recordView,devices],tabs=E('nav',{'class':'bj-tabs','aria-label':_('计费功能')},['概览','用量与账单','在线设备'].map(function(text,index){const tab=button(text,function(){Array.from(tabs.children).forEach(function(other,i){other.classList.toggle('active',i===index);other.setAttribute('aria-selected',String(i===index));sections[i].hidden=i!==index;});});tab.setAttribute('role','tab');tab.setAttribute('aria-selected',String(index===0));if(index===0)tab.classList.add('active');return tab;}));tabs.setAttribute('role','tablist');
  function row(label,value){return E('div',{'class':'bj-bill-row'},[E('span',{},_(label)),E('strong',{},String(value==null || value===''?'--':value))]);}
  function number(value,suffix,scale){return value!=='' && value!=null && Number.isFinite(Number(value))?(Number(value)/(scale || 1)).toFixed(2)+' '+suffix:'--';}
  function update(){
   busy=jobs.some(function(job){return job.running || job.starting;});submit.disabled=uplink.disabled=account.disabled=busy;message.textContent=busy?_('正在查询各条上游…'):_('路由器查询已完成');
   const unique=new Map();jobs.forEach(function(job){if(job.item.account && ['ready','loading'].includes(job.item.state))unique.set(job.item.account,job.item);});const items=Array.from(unique.values());
   function sum(key,suffix,scale){const values=items.map(function(item){return item[key]==='' || item[key]==null?NaN:Number(item[key]);});return values.length && values.every(function(value){return Number.isFinite(value) && (key==='balance' || value>=0);})?number(values.reduce(function(a,b){return a+b;},0),suffix,scale):'--';}
   const metrics=[['已查询账号',String(items.length)],['余额合计',sum('balance','元')],['总流量',sum('totalFlow','GB',1024)],['剩余流量',sum('remainingFlow','GB',1024)]];
   if(JSON.stringify(metrics)!==summaryStamp){summaryStamp=JSON.stringify(metrics);metrics.forEach(function(item,i){let card=summary.children[i];if(!card){card=E('article',{'class':'bj-card'},[E('span',{},_(item[0])),E('strong')]);summary.append(card);}card.lastElementChild.textContent=item[1];});}
   const stamp=JSON.stringify(jobs.map(function(job){return [job.item.account,job.item.state,job.sessions,job.sessionsAvailable];}));if(stamp!==devicesStamp){devicesStamp=stamp;const seen=new Set();const cards=jobs.filter(function(job){if(job.item.state!=='ready' || !job.item.account || seen.has(job.item.account))return false;seen.add(job.item.account);return true;}).map(function(job){return E('article',{'class':'bj-card'},[E('strong',{},_('账号')+' '+job.item.account)].concat((job.sessions || []).length?(job.sessions || []).map(function(session){return E('div',{'class':'bj-device'},[row('IPv4',session.ip),row('IPv6',session.ipv6),row('MAC',session.mac),row('在线时长',session.useTime?Math.round(Number(session.useTime)/60)+' 分钟':'--')]);}):[E('p',{},job.sessionsAvailable?_('暂无在线设备。'):_('在线设备暂时无法查询。'))]));});devices.replaceChildren.apply(devices,cards.length?cards:[E('p',{},_('请先查询计费账号。'))]);}
  }
  function draw(job){const item=job.item,stamp=JSON.stringify(item);if(job.card.dataset.result===stamp)return;job.card.dataset.result=stamp;job.card.replaceChildren(E('strong',{},job.title),E('p',{},item.message || _('等待查询')));
   if(item.state==='loading')job.card.append(E('progress',{max:100,value:item.percent || 2}));
   if(item.account)job.card.append(row('账号',item.account),row('余额',number(item.balance,'元')),row('总流量',number(item.totalFlow,'GB',1024)),row('剩余流量',number(item.remainingFlow,'GB',1024)),row('状态',item.accountStatus),row('套餐',item.package));
   if(item.state==='captcha')showCaptcha(job);
  }
  function showCaptcha(job){const image=E('img',{alt:_('计费系统验证码')}),input=E('input',{'class':'cbi-input-text',type:'text',maxlength:12,autocomplete:'off',placeholder:_('验证码')});if(/^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=]+$/.test(job.item.image || ''))image.src=job.item.image;
   async function answer(refreshImage){if(job.running || (!refreshImage && !input.value.trim()))return;job.running=true;update();try{const response=await captcha(job.ticket,L.env.sessionid,input.value.trim(),refreshImage);if(response.state==='error')throw new Error(response.message);job.item={state:'loading',message:_('正在核对验证码'),percent:40};draw(job);}catch(error){job.running=false;message.textContent=String(error.message || error);update();}}
   job.card.append(image,input,E('div',{'class':'bj-actions'},[button('换一张',function(){void answer(true);}),button('继续',function(){void answer(false);})]));
  }
  async function refresh(){if(busy)return;const selected=uplink.value==='all'?uplinks:uplinks.filter(function(item){return item.id===uplink.value;});if(!selected.length){message.textContent=_('请先在设置中添加上游。');return;}
   jobs=selected.map(function(item){return {uplink:item.id,account:account.value || 'current',ticket:'',running:false,starting:true,item:{state:'loading',message:_('正在准备查询'),percent:2},title:[item.device,item.network].filter(Boolean).join(' · ') || item.id,card:E('article',{'class':'bj-card bj-enter'})};});details.replaceChildren.apply(details,jobs.map(function(job){draw(job);return job.card;}));update();
   await Promise.all(jobs.map(async function(job){try{const response=await begin(job.uplink,job.account,L.env.sessionid);if(!response.ticket)throw new Error(response.message || _('无法开始查询'));job.ticket=response.ticket;job.running=true;}catch(error){job.item={state:'error',message:String(error.message || error)};draw(job);}finally{job.starting=false;}}));update();
  }
  uplink.addEventListener('change',refresh);account.addEventListener('change',refresh);
  poll.add(async function(){if(polling || !jobs.some(function(job){return job.running && job.ticket;}))return;polling=true;try{await Promise.all(jobs.filter(function(job){return job.running && job.ticket;}).map(async function(job){try{const response=await result(job.ticket,L.env.sessionid);job.item=response.result || response;job.running=job.item.state==='loading';job.sessions=response.sessions;job.sessionsAvailable=response.sessionsAvailable;draw(job);}catch(error){job.running=false;job.item={state:'error',message:String(error.message || error)};draw(job);}}));update();}finally{polling=false;}},2);
  Promise.resolve().then(refresh);return E('div',{'class':'bjut-workbench'},[bjut.style(),E('div',{'class':'bj-record-controls'},[E('label',{},[E('span',{},_('上游')),uplink]),E('label',{},[E('span',{},_('计费账号')),account]),submit]),message,tabs,overview,recordView,devices]);
 }
});
