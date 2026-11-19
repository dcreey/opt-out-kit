(function(token){var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return '';
  // The words naming a box: its label[for], else a wrapping label's own shown words.
  var own=function(e){var t=''; if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
    // A wrapping label's own words: its shown text (innerText: a label in a hidden bot trap shows none) without the options of a menu inside it.
    if(!t){var p=e.closest('label'); if(p){t=p.innerText||''; [].slice.call(p.querySelectorAll('option')).forEach(function(o){var x=(o.text||'').trim(); if(x) t=t.replace(x,' ');});}}
    if(!t) t=e.getAttribute('aria-label')||e.placeholder||e.name||'';
    return t;};
  var label=function(e){return own(e).replace(/\s+/g,' ').replace(/\*|\(required\)/gi,'').trim().slice(0,60);};
  var els=[].slice.call(f.querySelectorAll('select,input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button]),textarea,[contenteditable=""],[contenteditable="true"]'));
  for(var i=0;i<els.length;i++){var e=els[i], r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0) continue;
    var req=e.required||e.getAttribute('aria-required')==='true'||/\*/.test(own(e));
    if(!req) continue;
    var empty=e.tagName==='SELECT'?(!e.value||e.selectedIndex<=0&&!e.options[e.selectedIndex].value):!((('value' in e)?e.value:e.innerText)||'').trim();
    if(empty && !/captcha|code/i.test(label(e))) return label(e)||'a required choice';}
  return '';})
