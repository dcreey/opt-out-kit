(function(state){
  var opts=[].slice.call(document.querySelectorAll('[role=option],li[role=menuitem],[role=listbox] li,li[data-label],li[class*=option]')).filter(function(o){var r=o.getBoundingClientRect(); return r.width>0&&r.height>0;});
  var bad=/employee|customer|client|vendor|partner|supplier|business|contractor|applicant|agent|representative|former|prospect/i;
  // A request-type menu (azira.com's TrustArc form: Access, Delete, Opt-out, Do not sell, Withdraw consent, Limit, Correct): deletion, then opting out. A request to
  // see, correct, update or move the data is never chosen, not even as the last option of a list.
  var neverRequest=/\b(access|know|correct|updat|edit|rectif|portab|transfer|copy of|appeal|withdraw)/i;
  var good=[/delet|remov|erase|be forgotten/i,/opt.?out|do not sell|do not share|unsubscribe/i,/consumer|individual|myself|general public|member of the public/i,/^\s*(none|n\/a|not applicable|no relationship)/i,/\bother\b/i];
  bad=new RegExp(bad.source+'|'+neverRequest.source,'i');
  // The person's own state first, when the menu lists places (the name escaped so it is matched as written).
  if(state) good.unshift(new RegExp('^\\s*'+state.replace(/[.*+?^${}()|[\]\\\/]/g,'\\$&')+'\\b','i'));
  for(var g=0;g<good.length;g++){for(var i=0;i<opts.length;i++){var t=(opts[i].innerText||'').trim(); if(good[g].test(t)&&!bad.test(t)){opts[i].click(); return t;}}}
  if(opts.length&&opts.length<40){var last=opts[opts.length-1]; if(!bad.test(last.innerText||'')){last.click(); return (last.innerText||'').trim();}}
  // Nothing showed (the menu did not open on the first press): let the opener try it once more.
  if(!opts.length){var m=document.querySelector('[data-ook-menu="1"]:not([data-ook-menu-retry])'); if(m){m.removeAttribute('data-ook-menu'); m.setAttribute('data-ook-menu-retry','1');}}
  document.body.click(); return '';})
