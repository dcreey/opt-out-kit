(function(){
  var re=/^\s*(submit (a |your )?(privacy|data|consumer)( rights?)? request|(make|file|start) (a |your )?(privacy|data) request|your privacy choices|privacy (request|choices|center|preferences)|data subject( access)? request|do not (sell|share)( or (sell|share))?( my (personal )?(information|info|data))?|exercise your (privacy )?rights|manage (my )?privacy( settings| choices)?)\s*[.:]?\s*$/i;
  var els=[].slice.call(document.querySelectorAll('a,button,[role=button],li,span,div,p')).filter(function(e){
    var t=(e.innerText||'').trim(); if(t.length>60||!re.test(t)) return false; if(e.children.length>2) return false;
    var r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0) return false;
    var a=e.closest('a'); var h=a?(a.getAttribute('href')||''):''; return !/^mailto:/i.test(h);});
  els.sort(function(a,b){var ha=(a.closest('a')||a).getAttribute('href')||'', hb=(b.closest('a')||b).getAttribute('href')||''; var ma=(ha===''||ha==='#'||/^javascript:/i.test(ha))?0:1, mb=(hb===''||hb==='#'||/^javascript:/i.test(hb))?0:1; return ma-mb;});
  if(!els.length) return null; var e=els[0]; e.scrollIntoView({block:'center'});
  ['mousedown','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true}));});
  return (e.innerText||'').trim();})();
