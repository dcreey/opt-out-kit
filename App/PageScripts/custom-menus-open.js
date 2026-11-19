(function(){
  var els=[].slice.call(document.querySelectorAll('[role=combobox],[aria-haspopup=listbox],.MuiSelect-select')).filter(function(e){
    var r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&!e.getAttribute('data-ook-menu')&&((e.innerText||e.value||'').replace(/[\u200b\s]/g,'')==='');});
  if(!els.length) return '';
  var e=els[0]; e.setAttribute('data-ook-menu','1'); e.scrollIntoView({block:'center'});
  ['mousedown','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true}));});
  return ((e.closest('div[class*=FormControl],div')||e).innerText||'').replace(/\s+/g,' ').slice(0,120)||'menu';})();
