(function(){var re=/captcha|security.?code|verification|confirmation.?code|enter the (code|text|characters)|type the (code|characters)|one.?time|otp|passcode|\bcode\b/i, no=/zip|postal|promo|coupon|discount|area|country/i;
  var idle=Date.now()-(window.__ookUserAt||0);
  var els=document.querySelectorAll('input[type=text],input:not([type]),input[type=tel],input[type=number]');
  for(var i=0;i<els.length;i++){var e=els[i],r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0||!e.value) continue;
    var l=(e.name||'')+' '+(e.id||'')+' '+(e.placeholder||'')+' '+(e.getAttribute('aria-label')||'')+' '+(e.autocomplete||'');
    if(e.id){var lb=document.querySelector('label[for="'+e.id+'"]'); if(lb) l+=' '+lb.innerText;}
    if(!re.test(l)||no.test(l)) continue;
    if(e.getAttribute('data-ook-user')!=='1') continue;       // only a box the person typed in; one we filled is not theirs to wait for
    if((document.activeElement===e&&idle<12000)||idle<3000) return true;}
  return false;})();
