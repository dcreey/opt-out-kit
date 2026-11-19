(function(name){
  var el=document.querySelector('[name="'+name.replace(/"/g,'\"')+'"]')||document.getElementById(name);
  var form=el&&el.form; if(!form) return false;
  var buttons=form.querySelectorAll('button,input[type=submit],input[type=button]');
  for(var i=0;i<buttons.length;i++){var b=buttons[i],t=(b.innerText||b.value||'').trim();
    if(/agree|accept/i.test(t)) continue;
    var type=(b.getAttribute('type')||'submit').toLowerCase();
    if(type==='submit'){b.click();return true;}}
  if(form.requestSubmit){form.requestSubmit();return true;}
  form.submit();return true;})
