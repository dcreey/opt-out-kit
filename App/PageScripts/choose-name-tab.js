(function(){var vis=function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;};
  var items=[].slice.call(document.querySelectorAll('[role=tab],.nav-link,.tab,li,button,a,label,div,span')).filter(function(e){return vis(e)&&e.children.length<=1&&(e.innerText||'').trim().length<24;});
  var by=function(re){return items.filter(function(e){return re.test((e.innerText||'').trim());});};
  var names=by(/^(by )?(full )?(name|name lookup|people|person)$/i), phones=by(/^(by )?(phone|phone number|phone lookup|number)$/i);
  if(!names.length||!phones.length) return false;
  var n=names.filter(function(e){return /^(A|BUTTON)$/.test(e.tagName)||e.getAttribute('role')==='tab';})[0]||names.filter(function(e){return e.children.length===0;})[0]||names[0]; if(n.getAttribute('aria-selected')==='true'||/\bactive\b|\bselected\b/.test(n.className||'')) return false;
  n.click(); return true;})();
