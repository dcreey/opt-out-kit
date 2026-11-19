(function(){var W=window.__ook;
  if(!W){W=window.__ook={dirty:true,last:Date.now()};
    try{new MutationObserver(function(rs){for(var i=0;i<rs.length;i++){var r=rs[i];
      if(r.type==='attributes'&&/^data-ook/.test(r.attributeName||'')) continue; W.dirty=true; W.last=Date.now(); return;}})
      .observe(document.documentElement,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['class','style','hidden','open','aria-hidden','aria-expanded','src','disabled']});}catch(e){}}
  if(!W.ev){W.ev=true; var mark=function(){W.dirty=true;W.last=Date.now();}; document.addEventListener('change',mark,true); document.addEventListener('click',mark,true);}
  if(W.dirty&&Date.now()-W.last>=600){W.dirty=false;return true;} return false;})();
