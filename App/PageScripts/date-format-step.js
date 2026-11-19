(function(step){var bad=0, more=false;
  function visible(e){var r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&getComputedStyle(e).visibility!=='hidden'&&(e.innerText||'').trim()!=='';}
  function invalid(el){
    if(el.willValidate&&!el.checkValidity()) return true;
    if(el.getAttribute('aria-invalid')==='true') return true;
    var cls=(el.className||'')+' '+(el.parentElement?el.parentElement.className||'':''); if(/(^|[\s_-])(is-invalid|invalid|has-error|ng-invalid|error)($|[\s_-])/i.test(cls)) return true;
    var n=el.parentElement; for(var up=0;n&&up<2;up++,n=n.parentElement){var errs=n.querySelectorAll('[role=alert],.error,.invalid-feedback,.field-error,.help-block,[class*=error]');
      for(var i=0;i<errs.length;i++) if(!errs[i].contains(el)&&visible(errs[i])&&/date|birth|dob|format|valid|invalid|required|mm|dd|yyyy/i.test(errs[i].innerText)) return true;}
    return false;}
  function set(el,v){var d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
    ['input','change','blur','focusout'].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}));}); el.setAttribute('data-ook-last',el.value);}
  [].slice.call(document.querySelectorAll('[data-ook-dob]')).forEach(function(el){
    if(el.getAttribute('data-ook-user')==='1'||el.value!==el.getAttribute('data-ook-last')) return;
    var m=/^(\d{4})-(\d{2})-(\d{2})$/.exec(el.getAttribute('data-ook-dob')); if(!m) return; var y=m[1],mo=m[2],d=m[3];
    ['blur','focusout'].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}));});
    if(!invalid(el)) return;
    var mn=['January','February','March','April','May','June','July','August','September','October','November','December'][+mo-1];
    var forms=[mo+'/'+d+'/'+y,d+'/'+mo+'/'+y,y+'-'+mo+'-'+d,mo+'-'+d+'-'+y,d+'-'+mo+'-'+y,y+'/'+mo+'/'+d,d+'.'+mo+'.'+y,mo+d+y,d+mo+y,y+mo+d,mn+' '+(+d)+', '+y,(+d)+' '+mn.slice(0,3)+' '+y,(+mo)+'/'+(+d)+'/'+y];
    bad++;
    var next=+(el.getAttribute('data-ook-step')||0)+1;
    if(next<forms.length){el.setAttribute('data-ook-step',String(next)); set(el,forms[next]); more=true;} else { set(el,forms[0]); }
  });
  return JSON.stringify({bad:bad,more:more});})
