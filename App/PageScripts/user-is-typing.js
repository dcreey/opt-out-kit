(function(){var a=document.activeElement; if(!a) return false; var t=window.__ookUserAt||0; if(Date.now()-t>45000) return false;
  var tag=a.tagName; if(tag==='IFRAME') return true; if(tag==='TEXTAREA'||a.isContentEditable) return true;
  return tag==='INPUT'&&!/^(checkbox|radio|button|submit|reset|image|file|range|color|hidden)$/i.test(a.type||'');})();
