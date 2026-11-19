(function(){
  var text=(document.body?document.body.innerText:'').toLowerCase();
  if(!/review (your )?(request|information|details)|please (review|confirm)|confirm your (request|submission)|check your (details|information)/.test(text)) return false;
  var bs=[].slice.call(document.querySelectorAll('button,input[type=submit],[role=button]')).filter(function(b){
    var t=((b.innerText||b.value||'')+'').replace(/\s+/g,' ').trim(), r=b.getBoundingClientRect();
    return r.width>0&&r.height>0&&/^(submit( request)?|confirm( request)?|send( request)?|yes,? submit)$/i.test(t);});
  if(!bs.length) return false; bs[bs.length-1].scrollIntoView({block:'center'}); bs[bs.length-1].click(); return true;})();
