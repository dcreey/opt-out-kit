(function(token){var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return '';
  //#include bot-trap
  // The words naming a box: its label[for], else a wrapping label's own shown words.
  var own=function(e){var t=''; if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
    // A wrapping label's own words: its shown text (innerText: a label in a hidden bot trap shows none) without the options of a menu inside it.
    if(!t){var p=e.closest('label'); if(p){t=p.innerText||''; [].slice.call(p.querySelectorAll('option')).forEach(function(o){var x=(o.text||'').trim(); if(x) t=t.replace(x,' ');});}}
    if(!t) t=e.getAttribute('aria-label')||e.placeholder||e.name||'';
    return t;};
  var label=function(e){return own(e).replace(/\s+/g,' ').replace(/\*|\(required\)/gi,'').trim().slice(0,60);};
  var els=[].slice.call(f.querySelectorAll('select,input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button]),textarea,[contenteditable=""],[contenteditable="true"]'));
  for(var i=0;i<els.length;i++){var e=els[i], r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0||botTrap(e)) continue;
    var req=e.required||e.getAttribute('aria-required')==='true'||/\*|\(required\)/i.test(own(e));
    if(!req) continue;
    var empty=e.tagName==='SELECT'?(!e.value||e.selectedIndex<=0&&!e.options[e.selectedIndex].value):!((('value' in e)?e.value:e.innerText)||'').trim();
    // A type-ahead menu (react-select, as TrustArc's "Resident of" on azira.com) empties its own text box once an option is chosen and shows the choice beside
    // it, keeping it in a hidden field named after the box: chosen, not empty.
    if(empty&&e.tagName==='INPUT'&&(e.getAttribute('aria-autocomplete')||e.getAttribute('role')==='combobox')){
      var held=e.id&&f.querySelector('input[type=hidden][name="'+e.id+'"]'), shown=false;
      for(var p=e.parentElement,d=0;p&&d<5&&!shown;p=p.parentElement,d++){var v=p.querySelector('[class*=singleValue],[class*=single-value],[class*=multiValue],[class*=multi-value],[class*=selected-value]'); shown=!!(v&&(v.innerText||'').trim());}
      if(shown||(held&&held.value)) empty=false;}
    // A state menu still empty after the fill does not list the person's state (becausal.com lists only the 19 states with privacy laws): said so.
    if(empty&&e.tagName==='SELECT'&&/state|reside|province/i.test(own(e)+' '+(e.name||'')+' '+(e.id||''))&&e.options.length>5) return (label(e)||'State')+': your state is not on its list';
    if(empty && !/captcha|code/i.test(label(e))) return label(e)||'a required choice';}
  return '';})
