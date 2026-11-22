(function(state){
  var opts=[].slice.call(document.querySelectorAll('[role=option],li[role=menuitem],[role=listbox] li,li[data-label],li[class*=option]')).filter(function(o){var r=o.getBoundingClientRect(); return r.width>0&&r.height>0;});
  var bad=/employee|customer|client|vendor|partner|supplier|business|contractor|applicant|agent|representative|former|prospect/i;
  var good=[/consumer|individual|myself|general public|member of the public/i,/^\s*(none|n\/a|not applicable|no relationship)/i,/\bother\b/i];
  // The person's own state first, when the menu lists places (the name escaped so it is matched as written).
  if(state) good.unshift(new RegExp('^\\s*'+state.replace(/[.*+?^${}()|[\]\\\/]/g,'\\$&')+'\\b','i'));
  for(var g=0;g<good.length;g++){for(var i=0;i<opts.length;i++){var t=(opts[i].innerText||'').trim(); if(good[g].test(t)&&!bad.test(t)){opts[i].click(); return t;}}}
  if(opts.length&&opts.length<40){var last=opts[opts.length-1]; if(!bad.test(last.innerText||'')){last.click(); return (last.innerText||'').trim();}}
  document.body.click(); return '';})
