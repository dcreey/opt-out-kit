(function(step){var bad=0, more=false;
  function hasCC(el){var n=el.parentElement; for(var up=0;n&&up<4;up++,n=n.parentElement){var ss=n.querySelectorAll('select');
    for(var i=0;i<ss.length;i++){var o=ss[i].options[ss[i].selectedIndex]; if(o&&/\+\d{1,3}\b/.test(o.text+' '+o.value)) return true;} if(n.tagName==='FORM') break;} return false;}
  function visible(e){var r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&getComputedStyle(e).visibility!=='hidden'&&(e.innerText||'').trim()!=='';}
  function invalid(el){
    if(el.willValidate&&!el.checkValidity()) return true;
    if(el.getAttribute('aria-invalid')==='true') return true;
    var cls=(el.className||'')+' '+(el.parentElement?el.parentElement.className||'':''); if(/(^|[\s_-])(is-invalid|invalid|has-error|ng-invalid|error)($|[\s_-])/i.test(cls)) return true;
    var n=el.parentElement; for(var up=0;n&&up<2;up++,n=n.parentElement){var errs=n.querySelectorAll('[role=alert],.error,.invalid-feedback,.field-error,.help-block,[class*=error]');
      for(var i=0;i<errs.length;i++) if(!errs[i].contains(el)&&visible(errs[i])&&/phone|number|digit|valid|format|invalid|required/i.test(errs[i].innerText)) return true;}
    return false;}
  function set(el,v){var d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
    ['input','change','blur','focusout'].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}));}); el.setAttribute('data-ook-last',el.value);}
  [].slice.call(document.querySelectorAll('[data-ook-phone]')).forEach(function(el){
    if(el.getAttribute('data-ook-user')==='1'||el.value!==el.getAttribute('data-ook-last')) return;
    var d=el.getAttribute('data-ook-phone'); if(d.length===11&&d[0]==='1') d=d.slice(1); if(d.length!==10) return;
    ['blur','focusout'].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}));});
    if(!invalid(el)) return;
    var a=d.slice(0,3),b=d.slice(3,6),c=d.slice(6);
    var forms=hasCC(el)?[d,a+'-'+b+'-'+c,'('+a+') '+b+'-'+c,a+'.'+b+'.'+c,a+' '+b+' '+c]:[d,'1'+d,'+1'+d,a+'-'+b+'-'+c,'('+a+') '+b+'-'+c,a+'.'+b+'.'+c,a+' '+b+' '+c,'+1 '+a+' '+b+' '+c,'1-'+a+'-'+b+'-'+c];
    bad++;
    if(step<forms.length){set(el,forms[step]); more=true;} else { set(el,d); }
  });
  return JSON.stringify({bad:bad,more:more});})
