(function(){if(window.__ookUserAt) return false; var re=/opt.?(me.?)?out|remove (me|my|this)|do not sell|delete my/i;
  var els=[].slice.call(document.querySelectorAll('a,button,input[type=submit],input[type=button],[role=button]')).filter(function(e){var t=(e.innerText||e.value||'').trim();
    if(!re.test(t)||t.length>60) return false; var r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&!(e.closest&&e.closest('nav,header,footer'));});
  if(!els.length) return false;
  if(els.some(function(e){var r=e.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight;})) return false;
  els[0].scrollIntoView({block:'center',behavior:'smooth'}); return true;})();
