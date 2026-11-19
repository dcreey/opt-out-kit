(function(){
  function abs(h){try{return new URL(h,location.href).href}catch(e){return null}}
  var links=[].slice.call(document.querySelectorAll('a[href]')).map(function(a){return {href:abs(a.getAttribute('href')),text:(a.innerText||'').trim().slice(0,120)};}).filter(function(l){return l.href;});
  var forms=[].slice.call(document.forms).map(function(f){
    var fields=[],hasSubmit=!!f.querySelector('button,input[type=submit]');
    [].slice.call(f.elements).forEach(function(el){
      var t=(el.type||el.tagName||'').toLowerCase();
      if(['hidden','submit','button','image','reset','fieldset','object','output'].indexOf(t)>=0) return;
      var label=''; if(el.id){var l=document.querySelector('label[for="'+el.id+'"]'); if(l) label=l.innerText;}
      if(!label) label=el.placeholder||el.getAttribute('aria-label')||el.name||'';
      fields.push({type:t==='select-one'?'select':t,name:el.name||el.id||'',label:String(label).replace(/\s+/g,' ').trim().slice(0,60)});});
    var a=f.getAttribute('action');
    return {action:a?abs(a):location.href,method:(f.method||'get').toLowerCase(),fields:fields,hasSubmit:hasSubmit};});
  return JSON.stringify({url:location.href,title:document.title||'',text:(document.body?document.body.innerText:'').slice(0,4000),links:links.slice(0,300),forms:forms});
})();
