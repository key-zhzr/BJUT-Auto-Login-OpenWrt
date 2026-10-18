'use strict';
'require baseclass';

const labels = { online:'互联网已连接', authenticated_limited:'已认证，探测受限', probe_uncertain:'连通性待确认', offline_suspected:'正在复核', busy:'正在检测', waiting_interface:'等待接口', cooldown:'等待重试', auth_rejected:'账号未通过', portal_not_found:'未发现认证网关', portal_not_ready:'等待认证网关', no_account:'请选择账号', stopped:'尚未运行', login_accepted:'登录已受理', blocked:'请检查上游', request_failed:'认证结果待确认',logged_out:'已注销',logout_failed:'注销待确认' };
const samples = new Map();
const css = `.bjut-workbench{scrollbar-gutter:stable both-edges;--bj-bg:#eef2f8;--bj-card:#fff;--bj-text:#182235;--bj-muted:#697a94;--bj-border:#dce3ed;--bj-blue:#3478f6;--bj-ok:#18b991;--bj-error:#ee6a75;color:var(--bj-text);font-size:14px;padding:8px 4px 20px}.bjut-workbench h2{font-size:26px;font-weight:700;margin:8px 0 16px}.bjut-workbench h3{font-size:17px;margin:0 0 12px}.bjut-workbench p{color:var(--bj-muted);margin:8px 0;overflow-wrap:anywhere}.bjut-workbench .bj-card{border:1px solid var(--bj-border);background:var(--bj-card);border-radius:18px;padding:20px;box-shadow:0 6px 18px #172b4d0c;min-width:0;margin:14px 0}.bjut-workbench .bj-header,.bjut-workbench .bj-actions{display:flex;gap:12px;align-items:center;justify-content:space-between;flex-wrap:wrap}.bjut-workbench .bj-header h2{margin:0}.bjut-workbench .bj-ports{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;padding:12px 0}.bjut-workbench .bj-port{border:1px solid var(--bj-border);border-radius:16px;background:var(--bj-card);min-width:0;text-align:center;overflow:hidden;box-shadow:0 5px 14px #172b4d0b}.bjut-workbench .bj-port-title{font-size:17px;font-weight:700;background:var(--bj-bg);padding:12px 8px}.bjut-workbench .bj-port-body{padding:16px 12px}.bjut-workbench .bj-port-icon{font-size:32px;line-height:1.2;color:var(--bj-blue);margin-bottom:8px}.bjut-workbench .bj-speed{font-weight:600;color:var(--bj-muted)}.bjut-workbench .bj-paths{display:flex;gap:4px;margin:14px 0 12px}.bjut-workbench .bj-path{flex:1;padding:4px;border-radius:8px;background:#92a2b526;color:var(--bj-muted);font-size:12px}.bjut-workbench .bj-path.ok{background:#18b99122;color:var(--bj-ok)}.bjut-workbench .bj-path.fail{background:#ee6a7522;color:var(--bj-error)}.bjut-workbench .bj-port-state{font-weight:600;min-height:40px;display:grid;place-items:center}.bjut-workbench .bj-port-meta{font-size:12px;color:var(--bj-muted);overflow-wrap:anywhere;margin:8px 0}.bjut-workbench .bj-traffic{display:grid;gap:5px;font-variant-numeric:tabular-nums;text-align:left;margin-top:14px}.bjut-workbench .bj-traffic small{float:right;color:var(--bj-muted)}.bjut-workbench .bj-select{display:block;width:100%;min-width:0;height:38px;margin:12px 0 8px}.bjut-workbench .bj-login{width:100%;min-height:38px}.bjut-workbench .bj-port-actions{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.bjut-workbench .bj-port-actions .bj-login{grid-column:1/-1}.bjut-workbench .bj-port-actions .btn{margin:0;min-width:0;padding:8px 4px}.bjut-workbench .bj-details{margin-top:10px;text-align:left;font-size:12px}.bjut-workbench .bj-details summary{cursor:pointer;color:var(--bj-muted)}.bjut-workbench .bj-summary{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:16px}.bjut-workbench .bj-summary strong{display:block;font-size:24px;color:var(--bj-blue);margin-top:8px}.bjut-workbench .bj-log{white-space:pre-wrap;overflow-wrap:anywhere;max-height:65vh;overflow:auto;font:12px/1.8 monospace;padding:16px;border-radius:14px;background:var(--bj-bg)}.bjut-workbench .bj-billing-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px}.bjut-workbench .bj-billing-grid>.bj-card{margin:0}.bjut-workbench progress{width:100%;height:8px;accent-color:var(--bj-blue)}@media(max-width:600px){html{scrollbar-width:thin}html::-webkit-scrollbar,.bjut-workbench :not(.bj-log)::-webkit-scrollbar{width:3px;height:3px}.bjut-workbench .bj-log::-webkit-scrollbar{width:8px;height:8px}.bjut-workbench .bj-ports{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.bjut-workbench .bj-card{padding:16px}.bjut-workbench .bj-port-body{padding:14px 8px}.bjut-workbench .bj-port-title{font-size:15px}.bjut-workbench .bj-port-actions .btn{font-size:12px;white-space:nowrap}.bjut-workbench .bj-billing-grid{grid-template-columns:1fr}}@media(prefers-color-scheme:dark){.bjut-workbench{scrollbar-gutter:stable both-edges;--bj-bg:#202735;--bj-card:#2b3341;--bj-text:#eef4fc;--bj-muted:#afbed1;--bj-border:#455064}}`;

function portIcon() {
 const parser = new DOMParser();
 return document.importNode(parser.parseFromString('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 3h16v13h-5v5H9v-5H4z"/><path d="M8 7v4m3-4v4m3-4v4m3-4v4M12 16v5"/></svg>', 'image/svg+xml').documentElement, true);
}

function bytes(value) {
	let n = Number(value) || 0, unit = 0;
	const units = ['B','KiB','MiB','GiB','TiB'];
	while (n >= 1024 && unit < 4) { n /= 1024; unit++; }
	return n.toFixed(unit > 1 ? 1 : 0) + ' ' + units[unit];
}
function rate(port) {
	const now = performance.now(), previous = samples.get(port.uplink);
	samples.set(port.uplink, {at:now,tx:Number(port.txBytes),rx:Number(port.rxBytes)});
	const seconds = previous ? (now - previous.at) / 1000 : 0;
	return seconds > .2 ? {tx:Math.max(0,Number(port.txBytes)-previous.tx)/seconds,rx:Math.max(0,Number(port.rxBytes)-previous.rx)/seconds} : {tx:0,rx:0};
}

function portGrid(actions) {
 const root=E('div',{'class':'bj-ports'}),entries=new Map();
 function text(entry,key,value){if(entry.fields[key].textContent!==value)entry.fields[key].textContent=value;}
 function create(item){
  const fields={},slot=function(key,tag,cls){return fields[key]=E(tag || 'span',{'class':cls || ''});};
  const selector=E('select',{'class':'cbi-input-select bj-select','aria-label':_('账号')});
  const note=slot('note','p','bj-port-meta');note.setAttribute('role','status');
  const entry={fields:fields,selector:selector,accounts:'',pending:null,item:item};
  async function act(kind,button){
   if(kind==='switchAccount' && !selector.value){note.textContent=_('请先选择要切换的账号');return;}
   button.disabled=true;
   try{const response=await actions[kind](item.id,selector.value);entry.pending={at:Date.now(),updated:entry.item.updated_at,message:response.message || _('操作已开始')};note.textContent=entry.pending.message;if(actions.changed)void actions.changed();}
   catch(error){note.textContent=String(error.message || error);}
   finally{button.disabled=false;}
  }
  const login=E('button',{'class':'btn cbi-button-action bj-login',type:'button',click:function(){void act('login',login);}},_('登录'));
  const change=E('button',{'class':'btn',type:'button',click:function(){void act('switchAccount',change);}},_('切换账号'));
  const logout=E('button',{'class':'btn',type:'button',click:function(){void act('logout',logout);}},_('注销'));
  const details=E('details',{'class':'bj-details'},[E('summary',{},_('网络详情')),slot('network','p'),slot('address4','p'),slot('address6','p'),slot('message','p')]);
  entry.element=E('article',{'class':'bj-port bj-enter'},[slot('title','div','bj-port-title'),E('div',{'class':'bj-port-body'},[
   E('div',{'class':'bj-port-icon','aria-hidden':'true'},portIcon()),slot('speed','div','bj-speed'),E('div',{'class':'bj-paths'},[slot('ipv4','span','bj-path'),slot('ipv6','span','bj-path')]),slot('state','div','bj-port-state'),note,
   E('div',{'class':'bj-traffic'},[E('div',{},[slot('tx'),slot('txRate','small')]),E('div',{},[slot('rx'),slot('rxRate','small')])]),selector,E('div',{'class':'bj-port-actions'},[login,actions.switchAccount?change:null,actions.logout?logout:null]),details])]);
  root.append(entry.element);return entry;
 }
 function update(data,portData,accountData){
  const ids=new Set((data.uplinks || []).map(function(item){return item.id;}));
  entries.forEach(function(entry,id){if(!ids.has(id)){entry.element.remove();entries.delete(id);samples.delete(id);}});
  (data.uplinks || []).forEach(function(item){
   let entry=entries.get(item.id);if(!entry){entry=create(item);entries.set(item.id,entry);}entry.item=item;
   const accounts=(accountData.accounts || []).filter(function(account){return account.hasPassword;}),stamp=JSON.stringify(accounts);
   if(stamp!==entry.accounts){const selected=entry.selector.value;entry.selector.replaceChildren(E('option',{value:''},_('自动选择账号')));accounts.forEach(function(account){entry.selector.append(E('option',{value:account.id},account.user+(account.enabled?'':_('（手动）'))));});if(accounts.some(function(account){return account.id===selected;}))entry.selector.value=selected;entry.accounts=stamp;}
   const port=(portData.ports || []).find(function(port){return port.uplink===item.id;}) || {},speed=Number(port.speedMbps),rates=rate(Object.assign({uplink:item.id},port));
   text(entry,'title',item.device || port.device || item.network || item.id);
   text(entry,'speed',port.linkUp===0?_('已断开'):speed?(speed>=1000?(speed/1000)+' GbE':speed+' Mbps'):item.transport==='wifi'?'Wi-Fi':_('有线'));
   [['ipv4',item.internet4],['ipv6',item.internet6]].forEach(function(pair){text(entry,pair[0],(pair[1]==='reachable'?'✓ ':pair[1]==='unreachable'?'× ':'— ')+(pair[0]==='ipv4'?'IPv4':'IPv6'));entry.fields[pair[0]].className='bj-path '+(pair[1]==='reachable'?'ok':pair[1]==='unreachable'?'fail':'');});
   text(entry,'state',_(labels[item.state] || item.state || '等待检测'));
   const pending=entry.pending && Date.now()-entry.pending.at<15000 && entry.pending.updated===item.updated_at;
   text(entry,'note',item.checking?item.check_message || _('正在检测…'):pending?entry.pending.message:item.account?_('账号')+' '+item.account:item.message || _('暂无认证账号'));
   text(entry,'tx','▲ '+bytes(port.txBytes));text(entry,'rx','▼ '+bytes(port.rxBytes));text(entry,'txRate',bytes(rates.tx)+'/s');text(entry,'rxRate',bytes(rates.rx)+'/s');
   text(entry,'network',[item.network,item.network6].filter(Boolean).join(' / '));text(entry,'address4','IPv4 '+(item.ipv4 || '--'));text(entry,'address6','IPv6 '+(item.ipv6 || '--'));text(entry,'message',item.message || '');
  });
 }
 return {element:root,render:function(data,portData,accountData){resize(root,function(){update(data,portData,accountData);});}};
}

const motion=new WeakMap();
function resize(element,update,finished){
 const height=element.getBoundingClientRect().height,old=motion.get(element);if(old){old.animation.cancel();old.restore();motion.delete(element);}
 update();const target=element.getBoundingClientRect().height;
 if(Math.abs(height-target)<1 || !element.animate || window.matchMedia('(prefers-reduced-motion: reduce)').matches){if(finished)finished();return;}
 const overflow=element.style.overflow,sizing=element.style.boxSizing;const restore=function(){element.style.overflow=overflow;element.style.boxSizing=sizing;};
 element.style.overflow='clip';element.style.boxSizing='border-box';
 const animation=element.animate([{height:height+'px'},{height:target+'px'}],{duration:target>height?220:180,easing:'cubic-bezier(.2,.7,.3,1)',fill:'both'});motion.set(element,{animation:animation,restore:restore});
 animation.onfinish=function(){if(motion.get(element)?.animation!==animation)return;if(finished)finished();animation.cancel();restore();motion.delete(element);};
}
const disclosureRoots=new WeakSet();
function disclosures(root){
 if(disclosureRoots.has(root))return root;disclosureRoots.add(root);
 const intended=new WeakMap();
 root.addEventListener('click',function(event){
  const summary=event.target.closest('summary'),details=summary?.parentElement;if(!summary || !root.contains(summary) || details.tagName!=='DETAILS' || event.target.closest('button,a,input,select'))return;
  event.preventDefault();const expanded=!(intended.has(details)?intended.get(details):details.open);intended.set(details,expanded);
  if(expanded){resize(details,function(){details.open=true;});}
  else {const before=details.getBoundingClientRect().height;details.open=false;const closed=details.getBoundingClientRect().height;details.open=true;
    // Animate the real details box; a collapse keeps descendants mounted.
   const old=motion.get(details);if(old){old.animation.cancel();old.restore();motion.delete(details);}
   if(!details.animate || window.matchMedia('(prefers-reduced-motion: reduce)').matches){details.open=false;return;}
   const overflow=details.style.overflow;details.style.overflow='clip';const animation=details.animate([{height:before+'px'},{height:closed+'px'}],{duration:180,easing:'cubic-bezier(.2,.7,.3,1)',fill:'both'});const restore=function(){details.style.overflow=overflow;};motion.set(details,{animation:animation,restore:restore});animation.onfinish=function(){if(motion.get(details)?.animation!==animation)return;details.open=!!intended.get(details);animation.cancel();restore();motion.delete(details);};
  }
 });return root;
}
return baseclass.extend({
 resize:resize,disclosures:disclosures,
	style: function() { return E('style', {}, css+`html{scrollbar-gutter:stable both-edges}.bjut-workbench :is(.bj-log,.bj-table-scroll){scrollbar-gutter:stable both-edges}.bjut-workbench .bj-record-controls.bj-billing-controls{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr) auto}.bjut-workbench .bj-record-controls.bj-billing-controls label{min-width:0}.bjut-workbench [hidden]{display:none!important}.bjut-workbench .bj-tabs{display:flex;gap:8px;flex-wrap:wrap;margin:16px 0}.bjut-workbench .bj-tabs .active{color:var(--bj-blue);background:#3478f61a}.bjut-workbench .bj-summary .bj-card{margin:0}.bjut-workbench .bj-bill-row{display:flex;justify-content:space-between;gap:12px;padding:8px 0}.bjut-workbench .bj-bill-row span{color:var(--bj-muted)}.bjut-workbench .bj-bill-row strong{text-align:right;overflow-wrap:anywhere}.bjut-workbench .bj-record-controls{display:flex;align-items:end;flex-wrap:wrap;gap:12px;margin:12px 0}.bjut-workbench .bj-record-controls label{flex:1;min-width:140px;display:grid;gap:6px}.bjut-workbench .bj-record-controls input,.bjut-workbench .bj-record-controls select{width:100%;min-height:42px}.bjut-workbench .bj-record-controls .btn{min-height:42px}.bjut-workbench .bj-table-scroll{overflow:auto;margin:16px 0}.bjut-workbench .bj-table{border-collapse:collapse;font-size:12px;min-width:100%}.bjut-workbench .bj-table th,.bjut-workbench .bj-table td{padding:10px;white-space:nowrap;text-align:left;border-bottom:1px solid var(--bj-border)}.bjut-workbench .bj-editor{display:grid;gap:16px}.bjut-workbench .bj-editor label{display:grid;gap:6px}.bjut-workbench .bj-editor label:has(input[type=checkbox]){display:flex}.bjut-workbench .bj-editor input,.bjut-workbench .bj-editor select{max-width:100%}.bjut-workbench .bj-account-name{font-size:18px}.bjut-workbench .bj-card img{display:block;max-width:100%;margin:12px 0}.bjut-workbench .bj-device{margin-top:16px}.bjut-workbench .bj-form{display:grid;gap:14px;padding:16px 0}.bjut-workbench .bj-form label{display:grid;gap:6px}.bjut-workbench .bj-form input,.bjut-workbench .bj-form select{width:100%;min-width:0;min-height:42px}.bjut-workbench details{margin:12px 0}.bjut-workbench summary{cursor:pointer;padding:8px 0}.bjut-workbench h4{margin:20px 0 12px}.bj-enter{animation:bjEnter .22s cubic-bezier(.22,1,.36,1)}@keyframes bjEnter{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}@media(prefers-reduced-motion:reduce){.bj-enter{animation:none}}`); },
	label: function(state) { return _(labels[state] || state || '等待检测'); },
	bytes: bytes,
	portGrid: portGrid,
	ports: function(data,portData,accountData,login) { const grid=portGrid({login:login});grid.render(data,portData,accountData);return grid.element; }
});
