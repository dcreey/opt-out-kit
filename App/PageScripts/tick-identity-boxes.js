(function(){var yes=/\bi (confirm|verify|am)\b.{0,60}\b(person|owner|me)\b.{0,40}(email|e-mail|address|account|request|record)/i,
      no=/penalty|perjury|agent|behalf|representative|authori[sz]ed to|attest|acknowledg|certif|terms|privacy policy|legal/i,n=0,
      ack=/may be required to verify my identity.{0,200}authori[sz]e .{0,60} to contact me/i,notAck=/terms|privacy policy|\bsell|market|newsletter|advertis|share my|third part/i,
      // A certification about the person themselves (FormFiller.selfCertification: the same words): "I certify under penalty of perjury that I am the individual ...
      // and that all information I have submitted is true and accurate" (missionwired.com). Never an agent-only box ("written proof of authorization").
      cert=/\bi (hereby )?(certify|declare|attest|affirm|confirm|swear)\b.{0,300}(\bi am (the|a) (individual|person|consumer|data subject|resident)\b|\b(individual|person|consumer|data subject) whose (personal )?(information|data)|\b(information|details) (i have |i've )?(submitted|provided|entered|given).{0,30}\b(is|are) (true|accurate|correct))/i,
      oath=/perjur|under oath|\bsworn\b|\bswear\b|penalt(y|ies)/i, // an oath is the person's to read and tick (FormFiller.legalOath, decided 2026-11-24)
      agentOnly=/written proof|power of attorney|on behalf of (the|a) (data subject|consumer|individual)|authori[sz]ed agent/i, selfAnswer=/\bi am (the|a) (individual|person|consumer|data subject)\b/i;
  document.querySelectorAll('input[type=checkbox]').forEach(function(c){
    if(c.checked) return;
    var t='';
    if(c.id){var l=document.querySelector('label[for="'+c.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=c.closest('label'); if(p) t=p.innerText;}
    // Only a container holding this box alone speaks for it; and a bot trap no person sees (off the page, hidden from assistive tech) is never ticked.
    if(!t){var q=c.parentElement; t=q&&q.querySelectorAll('input,select,textarea').length===1?q.innerText:'';}
    var r=c.getBoundingClientRect(); if(r.right<=0||r.bottom<=0||r.left>=window.innerWidth+1000||c.closest('[aria-hidden=true]')) return;
    t=t.replace(/\s+/g,' ').trim();
    if(oath.test(t)) return;
    if((yes.test(t)&&!no.test(t))||(ack.test(t)&&!notAck.test(t))||(cert.test(t)&&!notAck.test(t)&&(!agentOnly.test(t)||selfAnswer.test(t)))){c.click(); if(!c.checked){c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));} n++;}});
  return n;})();
