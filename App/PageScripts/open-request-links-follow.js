(function(){
  var host=location.hostname.replace(/^www\./,''), reg=host.split('.').slice(-2).join('.');
  var re=/^\s*(opt.?out( of (the )?sale( and sharing)?)?( request| form)?( here)?|(individual: )?opt.?out\/?(deletion)?( request)?( form)?|do not sell( or share)?( my (personal )?(information|info))?( request| form)?|submit (a )?(privacy|opt.?out|data) request|(privacy|data) (request|rights) form|delete (my|your) (data|information)|remove my information)\s*[.:]?\s*$/i;
  var as=[].slice.call(document.querySelectorAll('a[href]')).filter(function(a){
    var t=(a.innerText||'').replace(/\s+/g,' ').trim(); var h=a.getAttribute('href')||''; if(t.length>70||!re.test(t)) return false;
    if(/^(mailto:|tel:|javascript:|#)/i.test(h)) return false; var r=a.getBoundingClientRect(); if(r.width<=0||r.height<=0) return false;
    try{var u=new URL(a.href,location.href); return u.hostname.replace(/^www\./,'').split('.').slice(-2).join('.')===reg||/onetrust|trustarc|datasubject|ketch|transcend|osano|securiti|zendesk|force\.com|atlassian|termly|saymine/.test(u.hostname);}catch(e){return false;}});
  if(!as.length) return ''; as[0].scrollIntoView({block:'center'}); location.href=as[0].href; return as[0].href;})();
