(function(values,keepExisting){var filled=0, unmatched=[];
  // A box or menu the person changed themselves is theirs: later passes leave it alone. Only real input counts, never our own events.
  if(!window.__ookUserWatch){window.__ookUserWatch=true;
    ['input','change'].forEach(function(t){document.addEventListener(t,function(e){if(e.isTrusted&&e.target&&e.target.setAttribute) e.target.setAttribute('data-ook-user','1');},true);});}
  function isCE(el){return el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA'&&el.tagName!=='SELECT'&&!('value' in el);}
  function getVal(el){return isCE(el)?(el.innerText||''):(el.value||'');}
  // The first candidate that fits the box's own character limit (a message box with a short limit gets the short request); else the first, cut at a sentence end.
  function fit(el,c){var ml=(el.maxLength>0)?el.maxLength:(+el.getAttribute('maxlength')||0), c0=String(c[0]);
    if(!ml||c0.length<=ml) return c0;
    for(var i=1;i<c.length;i++){var ci=String(c[i]); if(ci.length<=ml) return ci;}
    var cut=c0.slice(0,ml), k=cut.lastIndexOf('. '); return k>20?cut.slice(0,k+1):cut.trim();}
  function setValue(el,v){
    if(isCE(el)){el.focus(); try{document.execCommand('selectAll',false,null); if(!document.execCommand('insertText',false,v)) el.textContent=v;}catch(e){el.textContent=v;}
      ['input','change','blur'].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}));}); return;}
    var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
    var d=Object.getOwnPropertyDescriptor(proto,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
    el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));}
  // A phone number is typed as plain digits, with no spaces or punctuation. Only a box that shows an error gets other shapes (see tryPhoneFormats).
  // A menu of country codes ("United States (+1)") beside the box already supplies the code, so then the box takes the number alone.
  function hasCountryCode(el){var n=el.parentElement; for(var up=0;n&&up<4;up++,n=n.parentElement){
      var ss=n.querySelectorAll('select'); for(var i=0;i<ss.length;i++){var o=ss[i].options[ss[i].selectedIndex]; if(o&&/\+\d{1,3}\b/.test(o.text+' '+o.value)) return true;}
      if(n.tagName==='FORM') break;}
    return false;}
  function fmtPhone(el,raw){var d=String(raw||'').replace(/\D/g,''); if(d.length===11&&d[0]==='1') d=d.slice(1);
    var pat=el.getAttribute('pattern');
    if(d.length===10&&pat){var a=d.slice(0,3),b=d.slice(3,6),c=d.slice(6); var fs=[d,'1'+d,'+1'+d,a+'-'+b+'-'+c];
      for(var k=0;k<fs.length;k++){try{if(new RegExp('^(?:'+pat+')$').test(fs[k])) return fs[k];}catch(e){break;}}}
    return d;}
  function isDobBox(el){return el.tagName==='INPUT'&&el.type!=='date'&&/birth|dob|born|\bdate\b/i.test((el.name||'')+' '+(el.id||'')+' '+(el.getAttribute('aria-label')||'')+' '+(el.placeholder||'')+' '+(el.id&&document.querySelector('label[for="'+el.id+'"]')?document.querySelector('label[for="'+el.id+'"]').innerText:'')+' '+(el.closest('label')?el.closest('label').innerText:''))&&!/street|address/i.test((el.name||'')+' '+(el.id||''));}
  // A birthdate, or today's date, in a text box starts in the shape its placeholder shows (dd/mm/yyyy, yyyy-mm-dd, ...), else month/day/year; a box that then shows an error gets the others (see tryDateFormats).
  function fmtDob(el,iso){var m=/^(\d{4})-(\d{2})-(\d{2})$/.exec(iso||''); if(!m) return iso; var y=m[1],mo=m[2],d=m[3];
    var ph=(el.getAttribute('placeholder')||'').toLowerCase(), sep;
    // No placeholder: the shape may be named elsewhere (a pattern, a data- format, a title, the text near the box, a calendar widget's format).
    if(!/[dmy]{2}/.test(ph)){var hint=''; [].slice.call(el.attributes).forEach(function(a){if(/format|mask|pattern|title|describedby|date/i.test(a.name)) hint+=' '+a.value;});
      var n=el.parentElement; for(var up=0;n&&up<2;up++,n=n.parentElement) hint+=' '+(n.innerText||'').slice(0,200);
      var f=/\b(dd|mm|yyyy|yy|d|m|y)\s*([\/.\-])\s*(dd|mm|yyyy|yy|d|m|y)\s*[\/.\-]\s*(dd|mm|yyyy|yy|d|m|y)\b/i.exec(hint); if(f) ph=(f[1]+f[2]+f[3]+f[2]+f[4]).toLowerCase();}
    sep=(ph.match(/[^a-z0-9\s]/)||['/'])[0];
    if(/^y{2,4}/.test(ph)) return y+sep+mo+sep+d; if(/^d/.test(ph)) return d+sep+mo+sep+y; return mo+sep+d+sep+y;}
  function isPhoneBox(el){return el.tagName==='INPUT'&&(el.type==='tel'||/phone|mobile|\bcell|whatsapp|\btel\b|telephone/i.test((el.name||'')+' '+(el.id||'')+' '+(el.getAttribute('aria-label')||'')+' '+(el.placeholder||'')));}
  // A phone split over three boxes (area code, prefix, line number: limits 3, 3 and 4) gets one part per box, never the whole number in each.
  function splitSeg(el,v){var ml=(el.maxLength>0)?el.maxLength:0; if(el.tagName!=='INPUT'||ml<3||ml>4) return null;
    var n=el.parentElement; for(var up=0;n&&up<4;up++,n=n.parentElement){
      var L=[].slice.call(n.querySelectorAll('input')).filter(function(e){return ['hidden','checkbox','radio','submit','button','file','image','reset'].indexOf(e.type)<0&&e.maxLength>0&&e.maxLength<=4;});
      if(L.length>3) return null;
      if(L.length===3&&L[0].maxLength===3&&L[1].maxLength===3&&L[2].maxLength===4){var i=L.indexOf(el); if(i<0) return null;
        var fv=null; for(var k=0;k<values.length;k++){if(values[k].name===L[0].getAttribute('data-ook')) fv=values[k];}
        var d=String(((fv||v).candidates||[])[0]||'').replace(/\D/g,''); if(d.length===11&&d[0]==='1') d=d.slice(1); if(d.length!==10) return null;
        return [d.slice(0,3),d.slice(3,6),d.slice(6)][i];}}
    return null;}
  values.forEach(function(v){var el=document.querySelector('[data-ook="'+v.name+'"]'); if(!el) return;
    if(el.getAttribute('data-ook-user')==='1'){filled++; return;}
    // Whatever is already in a box or menu stays, unless it is exactly what this fill put there before.
    // The one exception: a State or Country the page ships with (a default such as "CA") gives way to the person's own, since a page default is not the person's choice.
    var stateish=/\b(state|province|country)\b/i.test((v.label||'')+' '+(el.name||'')+' '+(el.id||''))&&!/birth|born|issu|licen|incorporat|e-?mail|phone/i.test((v.label||'')+' '+(el.name||'')+' '+(el.id||''));
    var shown=(el.tagName==='SELECT'?((el.options[el.selectedIndex]||{}).text||'')+'|'+el.value:getVal(el)).toLowerCase();
    var agrees=v.candidates.some(function(c){c=(c||'').toLowerCase().trim(); return c&&shown.split('|').some(function(x){return x.trim()===c;});});
    var pageDefault=stateish&&v.candidates.length&&v.candidates[0]!==null&&!agrees;
    // An email box that ships holding something that is not an address (a page's own "opt-out" or "your email") is not the person's: their address replaces it.
    var wantsAt=v.candidates.length&&v.candidates[0]!==null&&String(v.candidates[0]).indexOf('@')>0;
    var junkEmail=wantsAt&&el.tagName!=='SELECT'&&(el.type==='email'||/e-?mail/i.test((v.label||'')+' '+(el.name||'')+' '+(el.id||'')))&&getVal(el).trim()!==''&&getVal(el).indexOf('@')<0;
    if(pageDefault||junkEmail){/* falls through to be filled */}
    else if(el.tagName==='SELECT'){if(el.selectedIndex>0&&el.value!==''&&el.value!==el.getAttribute('data-ook-last')){filled++; return;}}
    else if(getVal(el).trim()!==''&&getVal(el)!==el.getAttribute('data-ook-last')){filled++; return;}
    if(el.tagName==='SELECT'){var done=false;
      for(var c=0;c<v.candidates.length&&!done;c++){var want=(v.candidates[c]||'').toLowerCase();
        for(var i=0;i<el.options.length;i++){var o=el.options[i];
          if(o.value.toLowerCase()===want||o.text.trim().toLowerCase()===want){el.value=o.value;done=true;break;}}}
      // Options such as "IL - Illinois" or "Illinois (IL)": a state name inside the text, or the two-letter code as a whole word.
      for(var c2=0;c2<v.candidates.length&&!done;c2++){var w2=(v.candidates[c2]||'').toLowerCase(); if(!w2) continue;
        for(var i2=0;i2<el.options.length;i2++){var o2=el.options[i2], tx=o2.text.trim().toLowerCase(); if(!o2.value&&!tx) continue;
          var hit=w2.length>2?tx.indexOf(w2)>=0:new RegExp('(^|[^a-z])'+w2+'([^a-z]|$)').test(tx);
          if(hit&&!/other|not listed|outside/.test(tx)){el.value=o2.value;done=true;break;}}}
      // An age (or any number) against a menu of brackets: "18-24", "65+", "under 18".
      if(!done&&/^\d{1,3}$/.test(String(v.candidates[0]||''))){var n3=+v.candidates[0];
        for(var i3=0;i3<el.options.length&&!done;i3++){var tx3=el.options[i3].text.replace(/,/g,''), r3, lo=null, hi=null;
          if(r3=/(\d{1,3})\s*(?:-|–|—|to)\s*(\d{1,3})/.exec(tx3)){lo=+r3[1];hi=+r3[2];}
          else if(r3=/(\d{1,3})\s*\+|(\d{1,3})\s*(?:and|or)\s*(?:over|older|above|up)|(?:over|above)\s*(\d{1,3})/i.exec(tx3)){lo=+(r3[1]||r3[2]||r3[3]);hi=999;}
          else if(r3=/(?:under|below|younger than)\s*(\d{1,3})/i.exec(tx3)){lo=0;hi=+r3[1]-1;}
          if(lo!==null&&n3>=lo&&n3<=hi){el.value=el.options[i3].value;done=true;}}}
      if(!done&&/state|province|region/i.test((el.name||'')+' '+(el.id||'')+' '+(el.getAttribute('aria-label')||''))){
        // No match for the person's state: take "Other US state" / "Other" / "Not listed" when the menu has one.
        for(var k=0;k<el.options.length&&!done;k++){var tx=el.options[k].text.trim();
          if(/^(other( u\.?s\.?( state)?s?)?|other state|not listed|outside (the )?u\.?s)/i.test(tx)){el.value=el.options[k].value;done=true;}}}
      if(done){el.dispatchEvent(new Event('change',{bubbles:true}));el.setAttribute('data-ook-last',el.value);filled++;}
      else if(el.required||/\*|required/i.test((el.getAttribute('aria-label')||'')+(el.closest('label')?el.closest('label').innerText:'')+(el.id&&document.querySelector('label[for="'+el.id+'"]')?document.querySelector('label[for="'+el.id+'"]').innerText:''))) unmatched.push((v.candidates[0]||'')+'');
    } else if(keepExisting&&!pageDefault&&!junkEmail&&getVal(el).trim()!==''){filled++;}
    else if(v.candidates.length&&v.candidates[0]!==null){var ph=!/[,;\n]/.test(String(v.candidates[0]))&&isPhoneBox(el), dob=!ph&&isDobBox(el)&&/^\d{4}-\d{2}-\d{2}$/.test(v.candidates[0]); var seg=ph?splitSeg(el,v):null; setValue(el,seg!==null?seg:ph?fmtPhone(el,v.candidates[0]):dob?fmtDob(el,v.candidates[0]):fit(el,v.candidates)); if(dob) el.setAttribute('data-ook-dob',v.candidates[0]); el.setAttribute('data-ook-last',getVal(el)); if(ph&&seg===null) el.setAttribute('data-ook-phone',String(v.candidates[0]).replace(/\D/g,'')); filled++;}});
  return JSON.stringify({filled:filled,unmatched:unmatched});})
