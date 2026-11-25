(function(state){
  // Only options that show: a closed list kept at its size but hidden by visibility or opacity (saymine's Country beside its State) is not the open menu.
  // A list still fading in counts as shown: with the app off screen the page is not drawn, so a menu's fade-in (MUI, Radix) never moves past its first frame
  // and its options would read as hidden for good (DataGrail's "relationship" menu was left empty in a background run).
  var fading=function(e){try{return !!e.getAnimations&&e.getAnimations().some(function(a){return a.playState!=='finished';});}catch(x){return false;}};
  var shown=function(e){var r=e.getBoundingClientRect(); if(!(r.width>0&&r.height>0)||getComputedStyle(e).visibility==='hidden') return false;
    for(var p=e,i=0;p&&i<8;p=p.parentElement,i++){if(getComputedStyle(p).opacity==='0'&&!fading(p)) return false;} return true;};
  var opts=[].slice.call(document.querySelectorAll('[role=option],li[role=menuitem],[role=listbox] li,li[data-label],li[class*=option]')).filter(shown);
  var bad=/employee|customer|client|vendor|partner|supplier|business|contractor|applicant|agent|representative|former|prospect/i;
  // "Right to Erasure" is a deletion (trustsuperset.com; "erase" alone missed it and the run chose "Opt-out of Sales").
  // A request-type menu (azira.com's TrustArc form: Access, Delete, Opt-out, Do not sell, Withdraw consent, Limit, Correct): deletion, then opting out. A request to
  // see, correct, update or move the data is never chosen, not even as the last option of a list.
  var neverRequest=/\b(access|know|correct|updat|edit|rectif|portab|transfer|copy of|appeal|withdraw)/i;
  var good=[/delet|remov|eras(e|ure)|be forgotten/i,/opt.?out|do not sell|do not share|unsubscribe/i,/consumer|individual|myself|data subject|(the )?person (it|the request) is about|general public|member of the public/i,/^\s*(none|n\/a|not applicable|no relationship)/i,/\bother\b/i];
  bad=new RegExp(bad.source+'|'+neverRequest.source,'i');
  // The person's own state first, when the menu lists places (the name escaped so it is matched as written).
  if(state) good.unshift(new RegExp('^\\s*'+state.replace(/[.*+?^${}()|[\]\\\/]/g,'\\$&')+'\\b','i'));
  // A menu of countries ("select your country of residence", choreograph.com): the person's state is a US state, so the United States.
  if(state) good.unshift(/^\s*(united states( of america)?|usa|u\.s\.a?\.?)\s*$/i);
  // A menu of US states that does not list the person's (a portal that takes requests only from states with a privacy law): nothing is chosen, never another
  // state by the last-option rule below, and the caller is told, so it can say so and offer the email instead.
  var usStates=/^\s*(alabama|alaska|arizona|arkansas|california|colorado|connecticut|delaware|district of columbia|florida|georgia|hawaii|idaho|illinois|indiana|iowa|kansas|kentucky|louisiana|maine|maryland|massachusetts|michigan|minnesota|mississippi|missouri|montana|nebraska|nevada|new hampshire|new jersey|new mexico|new york|north carolina|north dakota|ohio|oklahoma|oregon|pennsylvania|rhode island|south carolina|south dakota|tennessee|texas|utah|vermont|virginia|washington|west virginia|wisconsin|wyoming)\s*$/i;
  var places=opts.filter(function(o){return usStates.test(o.innerText||'');}).length;
  if(state&&places>=3&&!opts.some(function(o){return good[1].test((o.innerText||'').trim());})){document.body.click(); return 'not-offered:'+state;}
  for(var g=0;g<good.length;g++){for(var i=0;i<opts.length;i++){var t=(opts[i].innerText||'').trim(); if(good[g].test(t)&&!bad.test(t)){opts[i].click(); return t;}}}
  if(opts.length&&opts.length<40){var last=opts[opts.length-1]; if(!bad.test(last.innerText||'')){last.click(); return (last.innerText||'').trim();}}
  // Nothing showed (the menu did not open on the first press): let the opener try it once more.
  if(!opts.length){var m=document.querySelector('[data-ook-menu="1"]:not([data-ook-menu-retry])'); if(m){m.removeAttribute('data-ook-menu'); m.setAttribute('data-ook-menu-retry','1');}}
  document.body.click(); return '';})
