'use strict';
'require baseclass';
'require bjut-autologin.workbench as bjut';

function ids(value) { return Array.isArray(value)?value:String(value || '').split(/\s+/).filter(Boolean); }
function arrange(accounts,value) {
 const selected=ids(value),byId=new Map(accounts.map(function(account){return [account.id,account];}));
 return Array.from(new Set(selected.concat(accounts.map(function(account){return account.id;})))).filter(function(id){return byId.has(id);}).map(function(id){return byId.get(id);});
}
function read(root) {return Array.from(root.querySelectorAll('input[type=checkbox]:checked')).map(function(input){return input.value;});}
function create(accounts,value,id,disabled) {
 const selected=new Set(ids(value)),root=E('div',{id:id,'class':'bj-account-order'});
 function notify(){root.dispatchEvent(new CustomEvent('widget-change',{bubbles:true}));}
 function update(){Array.from(root.children).forEach(function(row,index){row.querySelector('[data-move=up]').disabled=disabled || index===0;row.querySelector('[data-move=down]').disabled=disabled || index===root.children.length-1;});}
 function move(row,direction){const other=direction<0?row.previousElementSibling:row.nextElementSibling;if(!other)return;bjut.resize(root,function(){if(direction<0)root.insertBefore(row,other);else root.insertBefore(other,row);update();});notify();}
 arrange(accounts,value).forEach(function(account){
  const input=E('input',{type:'checkbox',value:account.id,change:notify});input.checked=selected.has(account.id);input.disabled=!!disabled;
  const row=E('div',{'class':'bj-account-order-row'},[E('label',{},[input,E('span',{},account.user+(account.enabled===false?_('（仅手动）'):''))])]);
  row.append(E('button',{type:'button','class':'btn','data-move':'up','aria-label':_('上移')+' '+account.user,click:function(){move(row,-1);}},'↑'),E('button',{type:'button','class':'btn','data-move':'down','aria-label':_('下移')+' '+account.user,click:function(){move(row,1);}},'↓'));root.append(row);
 });update();return root;
}
return baseclass.extend({arrange:arrange,ids:ids,read:read,create:create});
