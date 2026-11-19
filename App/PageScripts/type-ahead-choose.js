(function(name){var want=name.toLowerCase();
  var opts=[].slice.call(document.querySelectorAll('[role=option],li[role=option],[role=listbox] li')).filter(function(o){var r=o.getBoundingClientRect(); return r.width>0&&r.height>0;});
  for(var i=0;i<opts.length;i++){var t=(opts[i].innerText||'').trim().toLowerCase(); if(t===want){
    ['mousedown','mouseup','click'].forEach(function(k){opts[i].dispatchEvent(new MouseEvent(k,{bubbles:true,cancelable:true}));}); return true;}}
  return false;})
