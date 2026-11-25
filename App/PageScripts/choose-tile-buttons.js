(function(){
  //#include ownership
  var vis=function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;};
  var n=0; window.__ookTiles=window.__ookTiles||{};
  document.querySelectorAll('label,legend,h2,h3,h4,p,span,div').forEach(function(h){
    var t=(h.innerText||'').replace(/\s+/g,' ').replace(/\s*required\s*$/i,'').trim(); if(t.length>140||h.children.length>3) return;
    // "Are you an authorized agent submitting a request on the behalf of someone else?" (blackbaud.com's OneTrust form, as tiles): the person asks for themselves: No.
    var agentQ=/\?\s*$/.test(t)&&/authori[sz]ed agent|on (the )?behalf of/i.test(t);
    if(!agentQ&&t.length>60) return;
    var who=/^\*?\s*(I am an?\b|(select )?(a |the |your )?request[eo]r type)/i.test(t), what=/^\*?\s*(select )?(an? |the )?(request type|right to exercise|type of request)/i.test(t);
    if(!who&&!what&&!agentQ) return;
    var box=h.parentElement, btns=[]; for(var up=0;up<4&&box;up++,box=box.parentElement){btns=[].slice.call(box.querySelectorAll('button,[role=button],[role=radio],[role=option],label,[class*=option],[class*=choice],[class*=tile]')).filter(function(b){return vis(b)&&b!==h&&(b.innerText||'').trim().length>1&&(b.innerText||'').trim().length<80&&b.children.length<=2;}); if(btns.length>=1) break;}
    // One tile is enough ("Select a Requestor Type": Consumer): it is still chosen only when it is the answer the person would give.
    if(btns.length<1) return;
    // A group is handled once per page: after that, and whenever the person has tapped any of its tiles, it is theirs. A heading and the block around it
    // can both read "I am a ...": a tile the app already tapped for one of them is never tapped again (a toggle would switch it back off).
    if(window.__ookTiles[t]) return; window.__ookTiles[t]=1;
    if(btns.some(touched)||btns.some(autoDone)||btns.some(function(b){return b.getAttribute('aria-pressed')==='true'||/selected|active|checked/.test(b.className||'');})) return;
    var bad=/employee|customer|client|vendor|partner|contractor|applicant|agent|representative|prospect|access|know|correct|updat|edit|transfer|portab|appeal/i;
    var prefs=agentQ?[/^no\b/i]:who?[/^other$/i,/consumer|individual|myself|general public|member of the public/i]:[/delet|remov|eras(e|ure)/i,/opt.?out|do not sell|do not share/i];
    for(var p=0;p<prefs.length;p++){for(var i=0;i<btns.length;i++){var bt=(btns[i].innerText||'').trim(); if(prefs[p].test(bt)&&!bad.test(bt)){window.__ookUserAt||btns[i].scrollIntoView({block:'center'}); markAuto(btns[i]); btns[i].click(); n++; return;}}}
  });
  return n;})();
