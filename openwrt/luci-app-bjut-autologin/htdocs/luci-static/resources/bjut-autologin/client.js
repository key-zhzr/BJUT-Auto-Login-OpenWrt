'use strict';
'require baseclass';
'require rpc';
'require request';

let sequence=0;
// Use LuCI's authenticated request transport, with a per-call timeout and no
// RPC batching: a slow billing request must not hold status/log reads behind it.
function call(method,args,timeout) {
 const id=++sequence;
 return request.post(rpc.getBaseURL(),{jsonrpc:'2.0',id:id,method:'call',params:[rpc.getSessionID(),'bjut-autologin',method,args || {}]}, {timeout:timeout || 5000,nobatch:true,credentials:true}).then(function(response){
  if(!response.ok)throw new Error(_('暂时无法读取路由器，请稍后重试'));
  const body=response.json();
  if(body.error || !Array.isArray(body.result) || body.result[0]!==0)throw new Error(body.result && body.result[0]===6?_('管理会话已过期，请重新登录'):_('路由器请求未完成'));
  const value=body.result[1] || {};
  if(value.state==='error')throw new Error(value.message || _('操作未完成'));
  return value;
 });
}
function watch(root,refresh,interval) {
 let timer=null,running=false,again=false,stopped=false,mounted=false;
 function stop(){stopped=true;if(timer!==null)window.clearTimeout(timer);window.removeEventListener('online',wake);window.removeEventListener('focus',wake);document.removeEventListener('visibilitychange',wake);observer.disconnect();}
 function delay(){return Math.max(.1,typeof interval==='function'?interval():interval || 2)*1000;}
 async function run(){
  if(stopped)return;
  if(!root.isConnected){if(mounted){stop();return;}timer=window.setTimeout(run,100);return;}
  mounted=true;if(running){again=true;return;}
  if(timer!==null)window.clearTimeout(timer);
  if(document.hidden){timer=window.setTimeout(run,delay());return;}
  running=true;again=false;const started=performance.now();
  try{await refresh();}catch(error){/* Views retain their last result and render an error. */}
  finally{running=false;if(!stopped)timer=window.setTimeout(run,again?0:Math.max(100,delay()-(performance.now()-started)));}
 }
 function wake(){if(!document.hidden)void run();}
 const observer=new MutationObserver(function(){if(mounted && !root.isConnected)stop();});
 observer.observe(document.body,{childList:true,subtree:true});
 window.addEventListener('online',wake);window.addEventListener('focus',wake);document.addEventListener('visibilitychange',wake);
 timer=window.setTimeout(run,0);
 return {refresh:run,stop:stop};
}
return baseclass.extend({call:call,watch:watch});
