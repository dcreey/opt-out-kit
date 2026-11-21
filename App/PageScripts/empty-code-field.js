(function(){var re=/captcha|security.?code|verification.?code|enter the (code|text|characters)|type the (code|characters)/i;
  var els=document.querySelectorAll('input[type=text],input:not([type]),input[type=tel],input[type=number]');
  for(var i=0;i<els.length;i++){var e=els[i],r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0) continue;
    var l=(e.name||'')+' '+(e.id||'')+' '+(e.placeholder||'')+' '+(e.getAttribute('aria-label')||'');
    if(e.id){var lb=document.querySelector('label[for="'+e.id+'"]'); if(lb) l+=' '+lb.innerText;}
    if(re.test(l)&&!e.value) return true;}
  
  // A code step the page shows only after a button that emails the code ("Email me a verification code"): its box is hidden for now, and the form must not be
  // sent until the person has asked for the code and typed it in.
  var ask=/\b(send|email|text|get|request|resend)\b[^.]{0,30}\b(code|passcode)\b/i, no=/zip|postal|promo|coupon|discount|area|country/i;
  var btns=document.querySelectorAll('button,input[type=button],input[type=submit],a[role=button]'), asks=false;
  for(var j=0;j<btns.length;j++){var b=btns[j],cs=getComputedStyle(b); if(cs.display!=='none'&&cs.visibility!=='hidden'&&ask.test((b.textContent||b.value||'')+'')){asks=true; break;}}          // by style, not layout: the page may not be laid out yet
  if(asks){
    var all=document.querySelectorAll('input');
    for(var k=0;k<all.length;k++){var c=all[k]; if(c.value||!/^(text|tel|number|)$/.test(c.type||'')) continue;
      var t=(c.name||'')+' '+(c.id||'')+' '+(c.placeholder||'')+' '+(c.getAttribute('aria-label')||'')+' '+(c.autocomplete||'');
      var wrap=c.closest('label'); if(wrap) t+=' '+wrap.textContent;
      if(c.id){var lab=document.querySelector('label[for="'+c.id+'"]'); if(lab) t+=' '+lab.textContent;}
      if(/verification|security.?code|one.?time|otp|passcode|\bcode\b/i.test(t)&&!no.test(t)) return true;}
  }
  return false;})();
