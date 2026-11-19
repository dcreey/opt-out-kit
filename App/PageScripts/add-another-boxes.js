(function(token,wantE,wantP){
  var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return false;
  var vis=function(e){var r=e.getBoundingClientRect(),s=getComputedStyle(e);if(!(r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none')) return false;if(r.right<=0||r.left>=window.innerWidth+2000) return false;for(var a=e.parentElement,n=0;a&&n<8;a=a.parentElement,n++){var as=getComputedStyle(a);if(as.overflow!=='visible'&&a.getBoundingClientRect().height<=0) return false;}return true;};
  function lab(e){var t=''; if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=e.closest('label'); if(p) t=p.innerText;} return (t+' '+(e.getAttribute('aria-label')||'')+' '+(e.placeholder||'')).replace(/\s+/g,' ');}
  function kind(e){var t=e.type||'text'; if(['hidden','checkbox','radio','submit','button','file','image','reset'].indexOf(t)>=0) return '';
    var s=(e.name||'')+' '+(e.id||'')+' '+lab(e);
    if(/confirm|verify|re-?enter|retype|repeat/i.test(s)) return '';
    if(t==='email'||/e-?mail/i.test(s)) return 'e'; if(t==='tel'||/phone|mobile|\bcell\b|telephone/i.test(s)) return 'p'; return '';}
  function boxes(k){return [].slice.call(f.querySelectorAll('input')).filter(function(e){return vis(e)&&kind(e)===k;});}
  function press(k,kw){var bs=boxes(k); if(!bs.length) return false; var last=bs[bs.length-1];
    var near=last; for(var up=0;up<3&&near.parentElement&&near.parentElement!==f;up++) near=near.parentElement;
    var other=k==='e'?'p':'e';
    var cands=[].slice.call(f.querySelectorAll('button,a,[role=button],input[type=button],span,div')).filter(function(b){
      if(!vis(b)||b.children.length>3) return false;
      var t=((b.innerText||b.value||'')+' '+(b.getAttribute('aria-label')||'')+' '+(b.getAttribute('title')||'')).replace(/\s+/g,' ').trim();
      if(!t||t.length>60||/remove|delete|clear|submit|send|cancel|opt.?out|minus|^[-x\u2212\u00d7]$/i.test(t)) return false;
      if(b.tagName==='BUTTON'&&b.getAttribute('type')!=='button') return false;
      if(b.tagName==='INPUT'&&b.type!=='button') return false;
      if(b.getAttribute('type')==='submit') return false;
      if(b.tagName==='A'){var h=b.getAttribute('href')||''; if(h&&h!=='#'&&!/^javascript:/i.test(h)) return false;}
      if(b.hasAttribute('disabled')||b.getAttribute('aria-disabled')==='true') return false;
      var n=+(b.getAttribute('data-ook-added')||0); if(n>=5) return false;
      if(new RegExp('(add|another|more|\\+).{0,25}(' + kw + ')|(' + kw + ').{0,25}(add|another|more)\\b','i').test(t)) return true;
      // A bare "Add another" / "+" counts only when it sits right beside this kind of box and no box of the other kind.
      if(/^\+?\s*(add( another| more)?|another|more|\+)\s*$/i.test(t)&&near.contains(b)){
        var inNear=[].slice.call(near.querySelectorAll('input')).some(function(e){return vis(e)&&kind(e)===other;}); return !inNear;}
      return false;});
    // An outer wrapper with the same words is not the button: keep the innermost candidates, real buttons and links first.
    cands=cands.filter(function(c){return !cands.some(function(o){return o!==c&&c.contains(o);});});
    var rank=function(c){return (c.tagName==='BUTTON'||c.tagName==='A'||c.tagName==='INPUT'||c.getAttribute('role')==='button')?0:1;};
    cands.sort(function(a,b){return rank(a)-rank(b);});
    if(!cands.length) return false; var b=cands[0];
    b.setAttribute('data-ook-added',String((+(b.getAttribute('data-ook-added')||0))+1)); b.scrollIntoView({block:'center'}); b.click(); return true;}
  // A page can cap its boxes (two extra emails at most) while the button stays: a press that added no box of its kind ends the pressing for that kind.
  var st=window.__ookAdd=window.__ookAdd||{};
  function go(k,want,kw){var n=boxes(k).length; if(!(n>0&&n<want)) return false; if(st[token+k]!==undefined&&n<=st[token+k]) return false; var ok=press(k,kw); if(ok) st[token+k]=n; return ok;}
  if(go('e',wantE,'e-?mail')) return true;
  if(go('p',wantP,'phone|number|mobile|cell')) return true;
  return false;})
