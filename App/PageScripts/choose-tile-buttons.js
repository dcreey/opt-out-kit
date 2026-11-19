(function(){
  //#include ownership
  var vis=function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;};
  var n=0; window.__ookTiles=window.__ookTiles||{};
  document.querySelectorAll('label,legend,h2,h3,h4,p,span,div').forEach(function(h){
    var t=(h.innerText||'').replace(/\s+/g,' ').replace(/\s*required\s*$/i,'').trim(); if(t.length>60||h.children.length>3) return;
    var who=/^\*?\s*I am an?\b/i.test(t), what=/^\*?\s*(select )?(the )?(request type|right to exercise|type of request)/i.test(t);
    if(!who&&!what) return;
    var box=h.parentElement, btns=[]; for(var up=0;up<4&&box;up++,box=box.parentElement){btns=[].slice.call(box.querySelectorAll('button,[role=button],[role=radio],[role=option],label,[class*=option],[class*=choice],[class*=tile]')).filter(function(b){return vis(b)&&b!==h&&(b.innerText||'').trim().length>1&&(b.innerText||'').trim().length<80&&b.children.length<=2;}); if(btns.length>=2) break;}
    if(btns.length<2) return;
    // A group is handled once per page: after that, and whenever the person has tapped any of its tiles, it is theirs. A heading and the block around it
    // can both read "I am a ...": a tile the app already tapped for one of them is never tapped again (a toggle would switch it back off).
    if(window.__ookTiles[t]) return; window.__ookTiles[t]=1;
    if(btns.some(touched)||btns.some(autoDone)||btns.some(function(b){return b.getAttribute('aria-pressed')==='true'||/selected|active|checked/.test(b.className||'');})) return;
    var bad=/employee|customer|client|vendor|partner|contractor|applicant|agent|representative|prospect|access|know|correct|updat|edit|transfer|portab|appeal/i;
    var prefs=who?[/^other$/i,/consumer|individual|myself|general public|member of the public/i]:[/delet|remov|erase/i,/opt.?out|do not sell|do not share/i];
    for(var p=0;p<prefs.length;p++){for(var i=0;i<btns.length;i++){var bt=(btns[i].innerText||'').trim(); if(prefs[p].test(bt)&&!bad.test(bt)){btns[i].scrollIntoView({block:'center'}); markAuto(btns[i]); btns[i].click(); n++; return;}}}
  });
  return n;})();
