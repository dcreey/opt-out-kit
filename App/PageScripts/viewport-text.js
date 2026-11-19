(function(){var out=[],h=innerHeight,w=innerWidth,n=0,tw=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_TEXT),x;
  while((x=tw.nextNode())&&n<4000){var t=(x.nodeValue||'').trim(); if(!t) continue; var e=x.parentElement; if(!e) continue;
    var r=e.getBoundingClientRect(); if(r.width===0||r.height===0||r.bottom<0||r.top>h||r.right<0||r.left>w) continue;
    var cs=getComputedStyle(e); if(cs.visibility==='hidden'||cs.display==='none') continue; out.push(t); n++;}
  return out.join('\n').slice(0,8000);})();
