(function(){var n=0; document.querySelectorAll('div,section,aside,dialog,[role=dialog]').forEach(function(e){
  var s=getComputedStyle(e); if(s.position!=='fixed'&&s.position!=='sticky') return;
  var t=(e.innerText||'').toLowerCase(); if(t.length>1500) return;
  if(/cookie|consent|gdpr|your privacy choices?:? we use|tracking technolog/.test(t)&&!e.querySelector('form')){e.style.setProperty('display','none','important');n++;}});
  document.querySelectorAll('iframe').forEach(function(f){var s=getComputedStyle(f); var txt='';
    try{txt=((f.contentDocument&&f.contentDocument.body&&f.contentDocument.body.innerText)||'').toLowerCase();}catch(e){}
    if((s.position==='fixed'||s.position==='absolute')&&/cookie|consent|axeptio|gdpr/.test(txt+' '+(f.id||'')+' '+(f.className||''))){f.style.setProperty('display','none','important');n++;}});
  document.querySelectorAll('[id*="axeptio" i],[class*="axeptio" i],[id*="cookie" i][style*="fixed"]').forEach(function(e){if(!e.querySelector('form')){e.style.setProperty('display','none','important');n++;}});
  document.documentElement.style.setProperty('overflow','auto','important'); document.body.style.setProperty('overflow','auto','important'); return n;})();
