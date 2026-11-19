(function(values){var filled=0;
function setValue(el,v){var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
  var d=Object.getOwnPropertyDescriptor(proto,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
  el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));}
values.forEach(function(v){
  var el=document.querySelector('[name="'+v.name.replace(/"/g,'\"')+'"]')||document.getElementById(v.name); if(!el) return;
  if(el.tagName==='SELECT'){var done=false;
    for(var c=0;c<v.candidates.length&&!done;c++){var want=v.candidates[c].toLowerCase();
      for(var i=0;i<el.options.length;i++){var o=el.options[i];
        if(o.value.toLowerCase()===want||o.text.trim().toLowerCase()===want){el.value=o.value;done=true;break;}}}
    if(done){el.dispatchEvent(new Event('change',{bubbles:true}));filled++;}
  } else {setValue(el,v.candidates[0]);filled++;}
});
return filled;})
