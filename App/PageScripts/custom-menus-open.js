(function(){
  var shown=function(e){var r=e.getBoundingClientRect(); return r.width>0&&r.height>0;};
  var els=[].slice.call(document.querySelectorAll('[role=combobox],[aria-haspopup=listbox],.MuiSelect-select')).filter(function(e){
    return shown(e)&&e.getAttribute('data-ook-menu')!=='1'&&((e.innerText||e.value||'').replace(/[​\s]/g,'')==='');});
  // A home-made menu (saymine and others): a box that shows only a placeholder ("Choose state", "Select...") beside a list of options that is hidden until the box is
  // pressed. The innermost such box is pressed; one already showing a choice is not, and nothing inside a real <select> is.
  if(!els.length){
    var ph=/^(choose|select|pick|please (choose|select))\b[^\n]{0,30}$/i;
    var cands=[].slice.call(document.querySelectorAll('label,button,div,span,[tabindex]')).filter(function(e){
      var t=(e.innerText||'').replace(/\s+/g,' ').trim();
      if(!ph.test(t)||!shown(e)||e.closest('[data-ook-menu],select')) return false;
      var box=e.parentElement; for(var d=0;d<3&&box&&box.querySelectorAll('li').length<3;d++) box=box.parentElement;
      return !!box&&[].slice.call(box.querySelectorAll('li')).filter(shown).length===0&&box.querySelectorAll('li').length>=3;});
    els=cands.filter(function(e){return !cands.some(function(o){return o!==e&&e.contains(o);});});
  }
  if(!els.length) return '';
  var e=els[0]; e.setAttribute('data-ook-menu','1'); window.__ookUserAt||e.scrollIntoView({block:'center'});
  ['mousedown','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true}));});
  // A type-to-search menu (react-select, as on TrustArc's forms) opens from its input: focus it and press the down arrow too.
  if(e.tagName==='INPUT'){try{e.focus();}catch(x){} e.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',keyCode:40,bubbles:true}));}
  return ((e.closest('div[class*=FormControl],div')||e).innerText||'').replace(/\s+/g,' ').slice(0,120)||'menu';})();
