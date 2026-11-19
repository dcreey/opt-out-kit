(function(){var mn=['January','February','March','April','May','June','July','August','September','October','November','December'];
  function forms(iso){var m=/^(\d{4})-(\d{2})-(\d{2})$/.exec(iso||''); if(!m) return null; var y=m[1],mo=m[2],d=m[3];
    return [mo+'/'+d+'/'+y,d+'/'+mo+'/'+y,y+'-'+mo+'-'+d,mo+'-'+d+'-'+y,d+'-'+mo+'-'+y,y+'/'+mo+'/'+d,d+'.'+mo+'.'+y,mo+d+y,d+mo+y,y+mo+d,mn[+mo-1]+' '+(+d)+', '+y,(+d)+' '+mn[+mo-1].slice(0,3)+' '+y,(+mo)+'/'+(+d)+'/'+y];}
  var boxes=[].slice.call(document.querySelectorAll('[data-ook-dob]')); var learnt=-1;
  boxes.forEach(function(el){var st=+(el.getAttribute('data-ook-step')||0); if(st>0&&el.value===el.getAttribute('data-ook-last')) learnt=st;});
  if(learnt<0) return 0; var n=0;
  boxes.forEach(function(el){if(/[dmy]{2}/i.test(el.getAttribute('placeholder')||'')||el.getAttribute('data-ook-step')||el.getAttribute('data-ook-user')==='1'||el.value!==el.getAttribute('data-ook-last')) return;
    var f=forms(el.getAttribute('data-ook-dob')); if(!f) return; var d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value'); if(d&&d.set){d.set.call(el,f[learnt]);}else{el.value=f[learnt];}
    ['input','change','blur','focusout'].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}));}); el.setAttribute('data-ook-last',el.value); el.setAttribute('data-ook-step',String(learnt)); n++;});
  return n;})();
