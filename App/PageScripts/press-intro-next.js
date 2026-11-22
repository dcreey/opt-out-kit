(function(){
  if(!/opt.?out|do.?not.?sell|remove|ccpa|privacy.?(request|rights|choices)/i.test(location.pathname+' '+document.title)) return false;
  var cs=[].slice.call(document.querySelectorAll('button,a,[role=button]')).filter(function(e){var t=(e.innerText||'').replace(/\s+/g,' ').trim(); var r=e.getBoundingClientRect();
    return /^(continue|next|get started|begin|proceed|start)$/i.test(t)&&r.width>0&&r.height>0&&!e.disabled&&!e.closest('form,[id*=cookie i],[class*=cookie i],[id*=consent i],[class*=consent i],[class*=cmp i],[id*=onetrust i],[role=dialog],[aria-modal=true]');});
  if(cs.length!==1) return false;
  window.__ookUserAt||cs[0].scrollIntoView({block:'center'}); cs[0].click(); return true;})();
