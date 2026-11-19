(function(){var re=/^\s*(reject all|reject|decline|deny|no thanks|only necessary|necessary only|tout refuser|refuser|continuer sans accepter|rechazar todo|rechazar|solo necesarias|alle ablehnen|ablehnen|nur notwendige)\s*$/i;
var els=document.querySelectorAll('button,a,div,span,[role=button],input[type=button]');
for(var i=0;i<els.length;i++){var t=(els[i].innerText||els[i].value||'').trim();
if(re.test(t)){els[i].click();return true;}}return false;})();
