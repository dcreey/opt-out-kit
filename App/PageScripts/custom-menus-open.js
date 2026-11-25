(function(state){
  // Shown: a size, and not hidden by visibility or a see-through box (saymine's closed lists keep their size, hidden with visibility and opacity).
  // A list still fading in counts as shown: with the app off screen the page is not drawn, so a menu's fade-in (MUI, Radix) never moves past its first frame
  // and its options would read as hidden for good (DataGrail's "relationship" menu was left empty in a background run).
  var fading=function(e){try{return !!e.getAnimations&&e.getAnimations().some(function(a){return a.playState!=='finished';});}catch(x){return false;}};
  var shown=function(e){var r=e.getBoundingClientRect(); if(!(r.width>0&&r.height>0)||getComputedStyle(e).visibility==='hidden') return false;
    for(var p=e,i=0;p&&i<8;p=p.parentElement,i++){if(getComputedStyle(p).opacity==='0'&&!fading(p)) return false;} return true;};
  // A menu about a company ("Country / Territory of Registration of Company 1", dnb.com) is not the person's: it is left alone, as the type-ahead step does.
  var aboutCompany=function(e){var t=(e.getAttribute('aria-label')||'')+' '+(e.getAttribute('aria-labelledby')||'').split(/\s+/).map(function(id){var n=id&&document.getElementById(id); return n?n.innerText:'';}).join(' ');
    var p=e.parentElement; for(var i=0;i<3&&p;i++,p=p.parentElement){if(p.querySelectorAll('input,select,[role=combobox]').length>1) break; t+=' '+(p.innerText||'').slice(0,120);}
    return /\b(company|business|employer|organi[sz]ation)\b/i.test(t);};
  // A type-to-search menu (react-select) keeps its typing box see-through until the person types (choreograph.com's "select your country of residence"): it is
  // judged by the box around it, and it is empty only when that box shows no chosen value either.
  var frame=function(e){return e.tagName==='INPUT'&&e.closest('[class*=control]');};
  // A value that reads as a prompt ("select your country of residence", shown by choreograph.com as if chosen) is no choice.
  var chosen=function(e){var f=frame(e), v=f&&f.querySelector('[class*=singleValue],[class*=single-value],[class*=multiValue],[class*=multi-value]');
    return !!v&&!/^\s*(choose|select|pick|please (choose|select))\b/i.test(v.innerText||'');};
  // A menu showing only its prompt ("Select request type" on trustsuperset.com's Radix menus, marked data-placeholder) holds no choice either: it is empty.
  var prompt=function(e){return e.tagName!=='INPUT'&&(e.hasAttribute('data-placeholder')||!!e.querySelector('[data-placeholder]')||
    /^(choose|select|pick|please (choose|select))\b[^\n]{0,40}$/i.test((e.innerText||'').replace(/\s+/g,' ').trim()));};
  var els=[].slice.call(document.querySelectorAll('[role=combobox],[aria-haspopup=listbox],.MuiSelect-select')).filter(function(e){
    return (shown(e)||(frame(e)&&shown(frame(e))))&&e.getAttribute('data-ook-menu')!=='1'&&((e.innerText||e.value||'').replace(/[​\s]/g,'')===''||prompt(e))&&!chosen(e)&&!aboutCompany(e);});
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
  // A Country or State menu the page set itself to another place (360mediadirect.com's saymine form and blackbaud.com's OneTrust form showed "Mexico" on the
  // phone, from where the page placed it; the form then said requests are not taken there): it is opened, so the picker sets the person's country and state,
  // as a plain <select> already is (`fill-live`). Only once a menu, and only a menu that shows a place.
  if(!els.length&&state){
    var esc=function(t){return t.replace(/[.*+?^${}()|[\]\\\/]/g,'\\$&');};
    var usa=/^\s*(united states( of america)?|usa|u\.s\.a?\.?|us)\s*$/i, mine=new RegExp('^\\s*'+esc(state)+'\\s*$','i');
    var labelOf=function(e){var t=(e.getAttribute('aria-label')||'')+' '+(e.getAttribute('aria-labelledby')||'').split(/\s+/).map(function(id){var n=id&&document.getElementById(id); return n?n.innerText:'';}).join(' ');
      // Only the menu's own block: the walk stops at a box that holds another control, so a sentence elsewhere on the page ("select your country of
      // residence" above a language menu) is not taken for this menu's title.
      var own=(e.innerText||'');
      for(var p=e.parentElement,i=0;i<4&&p;i++,p=p.parentElement){
        if(p.querySelectorAll('input,select,[role=combobox],[class*=selected-value],[class*=single-value]').length>2) break;
        var pt=(p.innerText||'').replace(own,''); if(/\b(country|state|province)\b/i.test(pt)){t+=' '+pt.slice(0,80); break;}}
      return t;};
    els=[].slice.call(document.querySelectorAll('[role=combobox],[aria-haspopup=listbox],.MuiSelect-select,[class*=selected-value],[class*=single-value]')).filter(function(e){
      if(!shown(e)||e.getAttribute('data-ook-menu')||e.getAttribute('data-ook-place')||e.closest('select')||aboutCompany(e)) return false;
      var v=(e.innerText||e.value||'').replace(/\s+/g,' ').trim(); if(!v||v.length>40||/^(choose|select|pick)\b/i.test(v)) return false;
      var lab=labelOf(e);
      if(/\bcountry\b/i.test(lab)) return !usa.test(v);
      if(/\b(state|province)\b/i.test(lab)) return !mine.test(v);
      return false;});
    // The menu's own button is pressed: the value shown sits inside it (saymine's label for its hidden checkbox, react-select's control). Only the one opened
    // is marked, so the next call opens the next one (360mediadirect.com showed Mexico and Zacatecas: both were marked and State was never opened).
    els=els.slice(0,1).map(function(e){e.setAttribute('data-ook-place','1'); return e.closest('label,[role=combobox],[aria-haspopup=listbox],[class*=control]')||e;});
  }
  if(!els.length) return '';
  var e=els[0]; e.setAttribute('data-ook-menu','1'); window.__ookUserAt||e.scrollIntoView({block:'center'});
  ['mousedown','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true}));});
  // A type-to-search menu (react-select, as on TrustArc's forms) opens from its input: focus it and press the down arrow too.
  if(e.tagName==='INPUT'){try{e.focus({preventScroll:true});}catch(x){} e.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',keyCode:40,bubbles:true}));}
  return ((e.closest('div[class*=FormControl],div')||e).innerText||'').replace(/\s+/g,' ').slice(0,120)||'menu';})
