(function(re){var rx=new RegExp(re,'i'),el=null;
document.querySelectorAll('div,section,form,dialog,[role=dialog]').forEach(function(e){var t=e.innerText||'';
  if(rx.test(t)&&t.length<9000&&(!el||t.length<el.innerText.length))el=e;});
var agree=/^\s*(i agree|i accept|agree|accept|j'accepte|accepter|tout accepter|acepto|aceptar|ich stimme zu|zustimmen|akzeptieren)\s*$/i;
for(var up=el,d=0;up&&d<4;up=up.parentElement,d++){
  var bs=up.querySelectorAll('button,a,[role=button],input[type=button],input[type=submit]');
  for(var i=0;i<bs.length;i++){var t=(bs[i].innerText||bs[i].value||'');if(agree.test(t)){bs[i].click();return true;}}}
return false;})
