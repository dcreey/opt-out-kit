(function(re){var rx=new RegExp(re,'i'),best=null;
document.querySelectorAll('div,section,form,dialog,[role=dialog]').forEach(function(el){var t=el.innerText||'';
  if(rx.test(t)&&t.length<9000&&(!best||t.length<best.innerText.length))best=el;});
if(!best)return null;
var agree=/^\s*(i agree|i accept|agree|accept|j'accepte|accepter|tout accepter|acepto|aceptar|ich stimme zu|zustimmen|akzeptieren)\s*$/i,hasButton=false;
for(var up=best,d=0;up&&d<4&&!hasButton;up=up.parentElement,d++){
  var bs=up.querySelectorAll('button,a,[role=button],input[type=button],input[type=submit]');
  for(var i=0;i<bs.length;i++){var t=(bs[i].innerText||bs[i].value||'');if(agree.test(t)){hasButton=true;break;}}}
if(!hasButton)return null;   // acceptable-use text in a page footer is not a prompt: nothing to accept
var host=location.hostname.split('.').slice(-2).join('.'),links=[];
document.querySelectorAll('a[href]').forEach(function(a){
  if(/terms|acceptable use|privacy|conditions|confidentialit|mentions l[ée]gales|t[ée]rminos|condiciones|privacidad|nutzungsbedingungen|datenschutz|agb/i.test((a.innerText||'')+' '+a.href)&&a.hostname.split('.').slice(-2).join('.')===host)links.push(a.href);});
return JSON.stringify({prompt:best.innerText,links:links.slice(0,4)});})
