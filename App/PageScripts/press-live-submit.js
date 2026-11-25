(function(token){var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return false;
  var bad=/agree|accept|cancel|clear|reset|back|add another|^\+|subscribe/i;
  // A sign-up, demo or contact button is never pressed, whatever the form around it says (an "unsubscribe" or opt-out button is fine).
  var signup=/subscribe|newsletter|sign.?up|register(?!ed)|create (an? )?account|\bjoin\b|waitlist|\bdemo\b|free trial|get started|contact sales|talk to|activation|log.?in|sign.?in|get in touch|send message|contact us|book a/i, optout=/opt.?out|unsubscribe|do not sell|remove|delete|privacy/i;
  var refuse=function(b){var t=((b.innerText||b.value||'')+'').trim(); return signup.test(t)&&!optout.test(t);};
  var bs=[].slice.call(f.querySelectorAll('button,input[type=submit],input[type=button],[role=button]')).filter(function(b){
    var t=((b.innerText||b.value||'')+'').trim(); var r=b.getBoundingClientRect(); return r.width>0&&r.height>0&&!bad.test(t);});
  var pick=null;
  for(var i=0;i<bs.length&&!pick;i++){var ty=(bs[i].getAttribute('type')||'').toLowerCase(); if(ty==='submit') pick=bs[i];}
  for(var i=0;i<bs.length&&!pick;i++){if(/submit|send|opt|continue|request|go|confirm|remove|delete/i.test((bs[i].innerText||bs[i].value||''))) pick=bs[i];}
  if(!pick&&bs.length) pick=bs[bs.length-1];
  if(pick&&refuse(pick)) return false;
  // Once the person has touched the page, a form with a required box still empty is not pressed: the browser would only scroll to that box (moving the
  // page under their finger) and send nothing. The app says a required box is still empty instead. Only a form the browser checks: one marked novalidate
  // checks itself and the browser neither stops nor scrolls (the arrests.org portals mark both "myself" and "agent" boxes required, one ticked is enough,
  // and the browser's own check, failing on the other, held every one of them back as "a required box is still empty").
  if(window.__ookUserAt&&f.tagName==='FORM'&&!f.noValidate&&f.checkValidity&&!f.checkValidity()) return 'invalid';
  if(pick){window.__ookUserAt||pick.scrollIntoView({block:'center'}); pick.click(); return true;}
  if([].slice.call(f.querySelectorAll('button,input[type=submit],[role=button]')).some(refuse)) return false;
  if(f.requestSubmit){f.requestSubmit(); return true;} f.submit(); return true;})
