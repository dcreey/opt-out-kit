(function(){var out=[]; document.querySelectorAll('a[href^="mailto:" i]').forEach(function(a){out.push((a.getAttribute('href')||'').replace(/^mailto:/i,'').split('?')[0]);});
  var m=(document.body?document.body.innerText:'').match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g)||[]; return JSON.stringify(out.concat(m));})();
