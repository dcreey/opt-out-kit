(function(){var bs=[].slice.call(document.querySelectorAll('button,a,[role=button],input[type=submit]')).filter(function(b){
  var t=((b.innerText||b.value||'')+'').replace(/\s+/g,' ').trim(), r=b.getBoundingClientRect();
  return r.width>0&&r.height>0&&/^(confirm( my)?( request| email| opt.?out)?|verify( my)?( request| email)?|complete( my)?( request)?|yes,? (confirm|opt out|delete))$/i.test(t);});
  if(!bs.length) return ''; window.__ookUserAt||bs[0].scrollIntoView({block:'center'}); return ((bs[0].innerText||bs[0].value||'')+'').trim();})();
