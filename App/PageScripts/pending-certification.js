(function(){var re=/acknowledg|certif|attest|authori[sz]e|i agree|i accept|consent|under penalty|on behalf|je certifie|j'atteste|je reconnais|j'accepte|consentement|certifico|atesto|reconozco|acepto|consentimiento|ich best[äa]tige|ich versichere|einwilligung|zustimmung|ich stimme/i,out=null;
  document.querySelectorAll('input[type=checkbox]').forEach(function(c){
    if(c.checked||out) return;
    var t='';
    if(c.id){var l=document.querySelector('label[for="'+c.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=c.closest('label'); if(p) t=p.innerText;}
    if(!t){var n=c.parentElement; t=n?n.innerText:'';}
    // "I am an authorized agent submitting on behalf of someone else" is an option for agents, not a requirement for the subject.
    if(re.test(t)&&!/\bagent\b|\bon behalf\b|representative|mandataire|repr[ée]sentant|au nom d|agente|representante|en nombre de|bevollm[äa]chtigt|im namen/i.test(t)) out=t.replace(/\s+/g,' ').trim().slice(0,140);});
  return out;})();
