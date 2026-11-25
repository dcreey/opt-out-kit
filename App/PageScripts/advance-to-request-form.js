(function(loose){
  var pref=[/delet|remov|eras(e|ure)/i,/opt.?out|do not sell|do not share/i], skip=/access|transfer|inaccur|correct|updat|appeal|know/i;
  var els=[].slice.call(document.querySelectorAll('button,a,[role=button],div,span,p')).filter(function(e){
    var t=(e.innerText||'').replace(/\s+/g,' ').trim(); var r=e.getBoundingClientRect();
    return (/^start .{3,50} request$/i.test(t)||/^(exert (my )?right to opt.?out|delete (my|your) (user )?(personal )?(data|information)|delete and opt.?out|opt.?out of (the )?(sale|sharing)( (and|or) sharing)?( of (my|your) (personal )?(data|information))?|i am the person opting out[\s\S]{0,70}|i am (a )?consumer[\s\S]{0,50}|opt.?out form|individual: opt.?out.{0,30})$/i.test(t)||(loose&&e.tagName!=='A'&&/^(opt.?out|do not sell( or share)?( my (personal )?(information|data))?|delete( my (data|information|account))?|remove me)$/i.test(t)))&&r.width>0&&r.height>0&&e.children.length<=2;});
  for(var p=0;p<pref.length;p++){for(var i=0;i<els.length;i++){var t=(els[i].innerText||'').trim();
    if(pref[p].test(t)&&!skip.test(t)){window.__ookUserAt||els[i].scrollIntoView({block:'center'}); els[i].click(); return t;}}}
  // An opt-out page whose only step is a bare "Continue" (theorg.com): pressed only when the page's own address or title says opt-out, no box of any kind is on screen,
  // exactly one such button is, and it is not part of a cookie or consent prompt.
  if(/opt.?out|do.?not.?sell|remove|ccpa|privacy.?(request|rights|choices)/i.test(location.pathname+' '+document.title)){
    var boxes=[].slice.call(document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]),select,textarea')).filter(function(i){var r=i.getBoundingClientRect();return r.width>0&&r.height>0;});
    if(!boxes.length){
      var cs=[].slice.call(document.querySelectorAll('button,a,[role=button]')).filter(function(e){var t=(e.innerText||'').replace(/\s+/g,' ').trim(); var r=e.getBoundingClientRect();
        return /^(continue|next|get started|begin|proceed)$/i.test(t)&&r.width>0&&r.height>0&&!e.closest('[id*=cookie i],[class*=cookie i],[id*=consent i],[class*=consent i],[class*=cmp i],[id*=onetrust i],[role=dialog],[aria-modal=true]');});
      if(cs.length===1){window.__ookUserAt||cs[0].scrollIntoView({block:'center'}); cs[0].click(); return (cs[0].innerText||'').trim();}
    }
  }
  return '';})
