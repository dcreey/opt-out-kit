(function(token){var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return '';
  var label=function(e){var t=''; if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=e.closest('label'); if(p) t=p.innerText;} if(!t) t=e.getAttribute('aria-label')||e.placeholder||e.name||'';
    return t.replace(/\s+/g,' ').replace(/\*|\(required\)/gi,'').trim().slice(0,60);};
  var els=[].slice.call(f.querySelectorAll('select,input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button]),textarea,[contenteditable=""],[contenteditable="true"]'));
  for(var i=0;i<els.length;i++){var e=els[i], r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0) continue;
    var req=e.required||e.getAttribute('aria-required')==='true'||/\*/.test(label(e)+(e.closest('label')?e.closest('label').innerText:''));
    if(!req) continue;
    var empty=e.tagName==='SELECT'?(!e.value||e.selectedIndex<=0&&!e.options[e.selectedIndex].value):!((('value' in e)?e.value:e.innerText)||'').trim();
    if(empty && !/captcha|code/i.test(label(e))) return label(e)||'a required choice';}
  return '';})
