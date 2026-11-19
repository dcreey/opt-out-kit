(function(){var changed=false;
  [].slice.call(document.querySelectorAll('select')).forEach(function(s){
    if(changed||s.closest('form')||s.getAttribute('data-ook-user')==='1'||s.getAttribute('data-ook-auto')==='1') return;
    var r=s.getBoundingClientRect(); if(r.width<=0||r.height<=0) return;
    var o=[].slice.call(s.options), bad=/opt.?in|\bknow\b|access|correct|portab|copy of|subscribe/i;
    var pick=o.filter(function(x){return /opt.?out|do not sell|don.?t sell/i.test(x.text)&&!bad.test(x.text);})[0]
          ||o.filter(function(x){return /\b(delet|eras|remov)\w*/i.test(x.text)&&!bad.test(x.text);})[0];
    if(!pick||s.value===pick.value) return;
    s.setAttribute('data-ook-auto','1'); s.value=pick.value;
    s.dispatchEvent(new Event('input',{bubbles:true})); s.dispatchEvent(new Event('change',{bubbles:true})); changed=true;});
  return changed;})();
