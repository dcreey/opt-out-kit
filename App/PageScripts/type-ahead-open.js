(function(kind,name){
  var strip=function(t){return (t||'').replace(/\([^)]*\)/g,' ');};
  var els=[].slice.call(document.querySelectorAll('input[aria-autocomplete]')).filter(function(e){
    var r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0||e.getAttribute('data-ook-ac-'+kind)) return false;
    var g=e.closest('.form-group'); g=g&&g.querySelector('label');
    var l=(strip(e.getAttribute('aria-label'))+' '+(e.id||'')+' '+(e.name||'')+' '+strip(((e.id&&document.querySelector('label[for="'+e.id+'"]'))?document.querySelector('label[for="'+e.id+'"]').innerText:''))+' '+strip(g?g.innerText:'')).toLowerCase();
    return kind==='country' ? /country/.test(l) : (/state|province|region|residence/.test(l)&&!/country/.test(l));});
  if(!els.length) return false;
  var e=els[0]; e.setAttribute('data-ook-ac-'+kind,'1');
  var d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value'); d.set.call(e,name);
  ['keydown','input','keyup'].forEach(function(t){e.dispatchEvent(new Event(t,{bubbles:true}));});
  ['mousedown','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true}));});
  return true;})
