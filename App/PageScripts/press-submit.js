(function(name){
  var el=document.querySelector('[name="'+(window.CSS&&CSS.escape?CSS.escape(name):name.replace(/["\\]/g,'\\$&'))+'"]')||document.getElementById(name);
  var form=el&&el.form; if(!form) return false;
  // As press-live-submit: once the person has touched the page, an invalid form is not pressed (the browser would scroll to the empty box).
  // Only a form the browser checks (see press-live-submit): one marked novalidate checks itself.
  if(window.__ookUserAt&&!form.noValidate&&form.checkValidity&&!form.checkValidity()) return 'invalid';
  var buttons=form.querySelectorAll('button,input[type=submit],input[type=button]');
  for(var i=0;i<buttons.length;i++){var b=buttons[i],t=(b.innerText||b.value||'').trim();
    if(/agree|accept/i.test(t)) continue;
    var type=(b.getAttribute('type')||'submit').toLowerCase();
    if(type==='submit'){b.click();return true;}}
  if(form.requestSubmit){form.requestSubmit();return true;}
  form.submit();return true;})
