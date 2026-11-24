(function(name){var want=name.toLowerCase();
  var opts=[].slice.call(document.querySelectorAll('[role=option],li[role=option],[role=listbox] li')).filter(function(o){var r=o.getBoundingClientRect(); return r.width>0&&r.height>0;});
  for(var i=0;i<opts.length;i++){var t=(opts[i].innerText||'').trim().toLowerCase(); if(t===want){
    ['mousedown','mouseup','click'].forEach(function(k){opts[i].dispatchEvent(new MouseEvent(k,{bubbles:true,cancelable:true}));}); return true;}}
  // No list showing (it closed again, as TrustArc's does on a phone): press the down arrow in the type-ahead box that has the cursor, which opens it again.
  if(!opts.length){var a=document.activeElement; if(a&&a.tagName==='INPUT'&&a.getAttribute('aria-autocomplete')&&a.value){a.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',keyCode:40,bubbles:true}));}}
  return false;})
