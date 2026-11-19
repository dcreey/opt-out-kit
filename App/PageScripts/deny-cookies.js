(function(){
  var docs=[document]; document.querySelectorAll('iframe').forEach(function(f){try{if(f.contentDocument) docs.push(f.contentDocument);}catch(e){}});
  var known=['#onetrust-reject-all-handler','#axeptio_btn_dismiss','#axeptio_btn_dismiss_all','#CybotCookiebotDialogBodyButtonDecline','button#truste-consent-required','.cc-deny','[data-cookiefirst-action=reject]',
             '.osano-cm-denyAll','#didomi-notice-disagree-button','button[aria-label*="Reject" i]','.cookie-reject','#cookie-reject','.ot-pc-refuse-all-handler'];
  for(var di=0;di<docs.length;di++){for(var i=0;i<known.length;i++){var e=docs[di].querySelector(known[i]); if(e&&e.offsetParent!==null){e.click();return known[i];}}}
  var re=/^\s*(reject( all)?( cookies| non-essential( cookies)?)?|deny( all)?|decline( all)?|i do not accept( cookies)?|only (necessary|essential)( cookies)?|necessary( cookies)? only|no,? thanks|disagree|refuse( all)?|do not accept|tout refuser|rechazar todo|alle ablehnen)\s*$/i;
  for(var dj=0;dj<docs.length;dj++){
    var els=docs[dj].querySelectorAll('button,a,[role=button],input[type=button],input[type=submit],div,span,li');
    for(var j=0;j<els.length;j++){var el=els[j],t=(el.innerText||el.value||'').trim();
      if(!re.test(t)||t.length>40) continue; if(el.children.length>1) continue;
      var r=el.getBoundingClientRect(); if(r.width<=0||r.height<=0) continue;
      el.click(); return t;}}
  return null;})();
