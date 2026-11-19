(function(){var yes=/\bi (confirm|verify|am)\b.{0,60}\b(person|owner|me)\b.{0,40}(email|e-mail|address|account|request|record)/i,
      no=/penalty|perjury|agent|behalf|representative|authori[sz]ed to|attest|acknowledg|certif|terms|privacy policy|legal/i,n=0,
      ack=/may be required to verify my identity.{0,200}authori[sz]e .{0,60} to contact me/i,notAck=/terms|privacy policy|\bsell|market|newsletter|advertis|share my|third part/i;
  document.querySelectorAll('input[type=checkbox]').forEach(function(c){
    if(c.checked) return;
    var t='';
    if(c.id){var l=document.querySelector('label[for="'+c.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=c.closest('label'); if(p) t=p.innerText;}
    if(!t){var q=c.parentElement; t=q?q.innerText:'';}
    t=t.replace(/\s+/g,' ').trim();
    if((yes.test(t)&&!no.test(t))||(ack.test(t)&&!notAck.test(t))){c.click(); if(!c.checked){c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));} n++;}});
  return n;})();
