(function(){var re=/verification|confirmation|one.?time|otp|passcode|security.?code|enter the code|\bcode\b/i, no=/zip|postal|promo|coupon|discount|area|country/i;
  var els=document.querySelectorAll('input[type=text],input:not([type]),input[type=tel],input[type=number]');
  for(var i=0;i<els.length;i++){var e=els[i],r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0) continue;
    var l=(e.name||'')+' '+(e.id||'')+' '+(e.placeholder||'')+' '+(e.getAttribute('aria-label')||'')+' '+(e.autocomplete||'');
    if(e.id){var lb=document.querySelector('label[for="'+e.id+'"]'); if(lb) l+=' '+lb.innerText;}
    if(re.test(l)&&!no.test(l)&&!e.value) return true;}
  return false;})();
