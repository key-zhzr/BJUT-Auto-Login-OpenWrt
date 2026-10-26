'use strict';
'require view';
'require rpc';
'require ui';
'require bjut-autologin.workbench as bjut';
const accounts = rpc.declare({object:'bjut-autologin',method:'accounts',expect:{}});
const change = rpc.declare({object:'bjut-autologin',method:'account_set',params:['account','enabled'],expect:{}});
const save = rpc.declare({object:'bjut-autologin',method:'account_save',params:['account','username','password','enabled','login_type','max_sessions'],expect:{}});
const remove = rpc.declare({object:'bjut-autologin',method:'account_delete',params:['account'],expect:{}});
const move = rpc.declare({object:'bjut-autologin',method:'account_move',params:['account','direction'],expect:{}});
return view.extend({
 handleSave:null,handleSaveApply:null,handleReset:null,
 load:function(){return accounts();},
 render:function(data){
  const rows=E('div'),message=E('p',{'role':'status'});let busy=false;
  function button(text,action){return E('button',{'class':'btn',type:'button',click:action},_(text));}
  async function execute(action){if(busy)return;busy=true;try{const result=await action();if(result.state!=='ready')throw new Error(result.message || _('操作未完成'));message.textContent=result.message;draw(await accounts());return true;}catch(error){message.textContent=String(error.message || error);return false;}finally{busy=false;}}
  function edit(item){
   const limit=E('input',{type:'number',min:0,max:32,value:item?item.configuredMaxSessions || 0:0});
   const user=E('input',{'class':'cbi-input-text',type:'text',value:item?item.user:'',maxlength:256,autocomplete:'off'}),password=E('input',{'class':'cbi-input-text',type:'password',maxlength:4096,autocomplete:'new-password',placeholder:item?_('留空保留原密码'):_('密码')}),enabled=E('input',{type:'checkbox',checked:!item || !!item.enabled});
   const protocol=E('select',{'class':'cbi-input-select'},[['auto','全部'],['bjut-sushe','bjut-sushe'],['bjut_wifi','bjut_wifi'],['lgn','lgn']].map(function(value){return E('option',{value:value[0]},_(value[1]));}));protocol.value=item?item.loginType || 'auto':'auto';
   const note=E('p',{'role':'status'}),submit=button('保存',async function(){if(!user.value.trim() || (!item && !password.value)){note.textContent=_('请填写账号和密码');return;}submit.disabled=true;const ok=await execute(function(){return save(item?item.id:'',user.value.trim(),password.value,enabled.checked?'1':'0',protocol.value,String(limit.value));});submit.disabled=false;if(ok){password.value='';ui.hideModal();}else note.textContent=message.textContent;});
   ui.showModal(item?_('编辑账号'):_('添加账号'),[bjut.style(),E('div',{'class':'bjut-workbench bj-editor'},[E('label',{},[_('账号'),user]),E('label',{},[_('密码'),password]),E('label',{},[_('适用认证方式'),protocol]),E('label',{},[_('同时在线上限（0 自动：普通 3 / VIP 5）'),limit]),E('label',{},[enabled,' '+_('参与自动登录')]),note,E('div',{'class':'bj-actions'},[button('取消',function(){password.value='';ui.hideModal();}),submit])])]);
  }
  function confirmDelete(item){ui.showModal(_('删除账号'),[E('p',{},_('删除账号')+' '+item.user+'？'),E('div',{'class':'right'},[button('取消',ui.hideModal),button('删除',async function(){if(await execute(function(){return remove(item.id);}))ui.hideModal();})])]);}
  function draw(next){rows.replaceChildren.apply(rows,(next.accounts || []).map(function(item,index,items){
   const up=button('上移',function(){void execute(function(){return move(item.id,'up');});}),down=button('下移',function(){void execute(function(){return move(item.id,'down');});});up.disabled=index===0;down.disabled=index===items.length-1;
   return E('article',{'class':'bj-card bj-header bj-enter'},[E('div',{},[E('strong',{'class':'bj-account-name'},item.user),E('p',{},(item.enabled?_('参与自动登录'):_('仅手动使用'))+' · '+(item.loginType==='auto'?_('全部'):item.loginType || _('全部')))]),E('div',{'class':'bj-actions'},[up,down,button('编辑',function(){edit(item);}),button(item.enabled?'停用自动登录':'启用自动登录',function(){void execute(function(){return change(item.id,item.enabled?'0':'1');});}),button('删除',function(){confirmDelete(item);})])]);
  }));if(!next.accounts || !next.accounts.length)rows.append(E('p',{},_('尚未添加账号。')));}
  draw(data);return E('div',{'class':'bjut-workbench'},[bjut.style(),E('div',{'class':'bj-actions'},[E('p',{},_('按此处顺序自动登录；停用后仍可手动选择。')),button('添加账号',function(){edit(null);})]),message,rows]);
 }
});
