(function(action,fields){var f=document.createElement('form');f.method='POST';f.action=action;
fields.forEach(function(kv){var i=document.createElement('input');i.type='hidden';i.name=kv[0];i.value=kv[1];f.appendChild(i);});
document.body.appendChild(f);f.submit();})
