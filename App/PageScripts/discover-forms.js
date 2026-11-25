(function(){
  //#include bot-trap
  var vis=function(e){var r=e.getBoundingClientRect(),s=getComputedStyle(e);if(!(r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none')) return false;if(r.right<=0||r.left>=window.innerWidth+2000) return false;for(var a=e.parentElement,n=0;a&&n<8;a=a.parentElement,n++){var as=getComputedStyle(a);if(as.overflow!=='visible'&&a.getBoundingClientRect().height<=0) return false;}return true;};
  var label=function(e){var t='';
    if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=e.closest('label'); if(p) t=p.innerText;}
    // Form builders (Tally, Typeform) put the question in a heading and point the box at it: aria-labelledby="label_<id>".
    if(!t){var lb=e.getAttribute('aria-labelledby'); if(lb) t=lb.split(/\s+/).map(function(id){var n=document.getElementById(id); return n?n.innerText:'';}).join(' ');}
    if(!t) t=e.getAttribute('aria-label')||e.getAttribute('title')||'';
    // The element just before the box (<span>Street</span><input>), unless it belongs to another box: a <label> holding a box of its own, or one for another
    // box on the page (a label pointing at an id that does not exist is usually this box's, with the page's own mistake in it).
    var pv=e.previousElementSibling, near='';
    if(!t&&pv&&!/^(INPUT|SELECT|TEXTAREA)$/.test(pv.tagName)&&!(pv.tagName==='LABEL'&&(pv.querySelector('input,select,textarea')||(pv.htmlFor&&pv.htmlFor!==e.id&&document.getElementById(pv.htmlFor))))) near=pv.innerText||'';
    // Or a short title beside a wrapper that holds only this box (klear.com: <div>First Name</div><div><div><input placeholder="John"></div></div>).
    if(!t&&!near){for(var a=e.parentElement,k=0;a&&k<3&&a.tagName!=='FORM';a=a.parentElement,k++){
      if(a.querySelectorAll('input:not([type=hidden]),select,textarea').length>1) break;
      var ps=a.previousElementSibling, pt=ps&&!ps.querySelector('input,select,textarea')?(ps.innerText||'').replace(/\s+/g,' ').trim():'';
      if(pt&&pt.length<=60){near=pt;break;}}}
    // A placeholder is often an example ("John", "john@doe.com"), not the box's name: it comes after the words beside the box, never instead of them.
    if(!t) t=[near,e.placeholder||''].filter(function(x){return x;}).join(' ');
    // Its parent's text, unless the parent holds other boxes too (then that text is theirs as much as this one's).
    if(!t&&e.parentElement&&e.parentElement.querySelectorAll('input:not([type=hidden]),select,textarea').length<=1) t=(e.parentElement.innerText||'').slice(0,60);
    return t.replace(/\s+/g,' ').trim().slice(0,90);};
  var ctxEl=function(e){var n=e; for(var i=0;i<8&&n&&n!==document.body;i++,n=n.parentElement){var t=(n.innerText||'').replace(/\s+/g,' ').trim(); if(t.length>=25&&t.length<=700) return n;} return e.parentElement||e;};
  // A rich-text message box (Quill, Draft, a plain contenteditable div) is a box too; it counts as a textarea.
  var ceSel=',[contenteditable=""],[contenteditable="true"],[role=textbox]:not(input):not(textarea)';
  var nestedCE=function(e){return e.tagName!=='INPUT'&&e.tagName!=='SELECT'&&e.tagName!=='TEXTAREA'&&!!(e.parentElement&&e.parentElement.closest('[contenteditable=""],[contenteditable="true"],[role=textbox]'));};
  var ftype=function(e){var t=e.tagName.toLowerCase(); return t==='select'?'select':(t==='textarea'||(t!=='input'&&!('value' in e)))?'textarea':(e.type||'text');};
  var headOf=function(f){var n=f;for(var i=0;i<6&&n&&n!==document.body;i++,n=n.parentElement){var p=n.previousElementSibling;for(var j=0;j<8&&p;j++,p=p.previousElementSibling){if(/^H[1-6]$/.test(p.tagName))return (p.innerText||'').replace(/\s+/g,' ').trim().slice(0,80);var h=p.querySelector&&p.querySelector('h1,h2,h3,h4,h5,h6');if(h)return (h.innerText||'').replace(/\s+/g,' ').trim().slice(0,80);}}return '';};
  var out=[];
  document.querySelectorAll('form').forEach(function(f,i){
    var ftoken='f'+i; f.setAttribute('data-ook-form',ftoken);
    var fields=[]; f.querySelectorAll('input,select,textarea'+ceSel).forEach(function(e,j){
      var type=ftype(e);
      if(['hidden','submit','button','image','reset'].indexOf(type)>=0||nestedCE(e)||(type==='textarea'&&e.tagName!=='TEXTAREA'&&!vis(e))) return;
      var token=ftoken+'-'+j; e.setAttribute('data-ook',token);
      var l=label(e);
      // A bot trap (`bot-trap`: hidden from assistive tech, or out of the tab order in a box one pixel tall) shows to no person: not visible, so it is not filled.
      fields.push({token:token,name:e.name||e.id||'',type:type,label:l,required:!!e.required||/\*/.test(l),visible:vis(e)&&!botTrap(e),disabled:!!e.disabled});});
    var buttons=[]; f.querySelectorAll('button,input[type=submit],input[type=button],[role=button]').forEach(function(b){
      if(vis(b)) buttons.push(((b.innerText||b.value||'')+'').trim().slice(0,60));});
    out.push({token:ftoken,action:f.getAttribute('action')||'',method:f.method||'get',visible:vis(f),fields:fields,buttons:buttons,
              text:(f.innerText||'').replace(/\s+/g,' ').trim().slice(0,240),ctx:(ctxEl(f).innerText||'').replace(/\s+/g,' ').trim().slice(0,600),head:headOf(f)});});
  // Single-page request portals put their inputs on the page without a <form>. Treat the loose inputs as one form.
  var loose=[].slice.call(document.querySelectorAll('input,select,textarea'+ceSel)).filter(function(e){
    return !e.closest('form')&&['hidden','submit','button','image','reset','search'].indexOf(e.type)<0&&vis(e)&&!nestedCE(e)&&!botTrap(e);});
  // A rich-text box alone is no form (a comment box); it joins the loose boxes only beside real inputs.
  if(!loose.some(function(e){return e.tagName==='INPUT'||e.tagName==='SELECT'||e.tagName==='TEXTAREA';})) loose=[];
  if(loose.length>=1&&document.body){
    document.body.setAttribute('data-ook-form','fx'); var lf=[];
    loose.forEach(function(e,j){var type=ftype(e);
      var token='fx-'+j; e.setAttribute('data-ook',token); var l=label(e);
      lf.push({token:token,name:e.name||e.id||'',type:type,label:l,required:!!e.required||/\*/.test(l),visible:true,disabled:!!e.disabled});});
    // The buttons that belong to these inputs: those in the same block of the page, else every button.
    var box=ctxEl(loose[0]); var lb=[]; box.querySelectorAll('button,input[type=submit],[role=button]').forEach(function(b){if(vis(b)) lb.push(((b.innerText||b.value||'')+'').trim().slice(0,60));});
    if(!lb.length) document.querySelectorAll('button,input[type=submit],[role=button]').forEach(function(b){if(vis(b)) lb.push(((b.innerText||b.value||'')+'').trim().slice(0,60));});
    out.push({token:'fx',action:'',method:'post',visible:true,fields:lf,buttons:lb.slice(0,12),text:(box.innerText||'').replace(/\s+/g,' ').trim().slice(0,240),ctx:(box.innerText||'').replace(/\s+/g,' ').trim().slice(0,600),head:headOf(box)});}
  return JSON.stringify(out);})();
