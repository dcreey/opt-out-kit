// Shared by the choosers (included with an "include ownership" line): what the person tapped or changed is theirs, and what the app chose once it does not choose again.
// A refill (after a check is solved, before sending) must never undo a tile, box or menu the person set, nor tap a tile a second time (a tile that
// toggles would switch our own choice off). Only real taps count (isTrusted), never our own clicks.
if(!window.__ookUserWatch){window.__ookUserWatch=true;
  ['input','change'].forEach(function(t){document.addEventListener(t,function(e){if(e.isTrusted&&e.target&&e.target.setAttribute) e.target.setAttribute('data-ook-user','1');},true);});}
if(!window.__ookClickWatch){window.__ookClickWatch=true; window.__ookTouched=[];
  document.addEventListener('click',function(e){if(e.isTrusted&&e.target&&e.target.nodeType===1){window.__ookTouched.push(e.target); if(window.__ookTouched.length>80) window.__ookTouched.shift();}},true);}
var touched=function(el){var t=window.__ookTouched||[];
  for(var i=0;i<t.length;i++){var x=t[i]; var lab=x.closest?x.closest('label'):null;
    if(x===el||el.contains(x)||(x.tagName==='LABEL'&&x.htmlFor&&x.htmlFor===el.id)||(lab&&lab.contains(el))) return true;}
  return el.getAttribute('data-ook-user')==='1';};
var autoDone=function(el){return el.getAttribute('data-ook-auto')==='1';};
var markAuto=function(el){el.setAttribute('data-ook-auto','1');};
