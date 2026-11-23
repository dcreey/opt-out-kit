(function(){var re=/acknowledg|certif|attest|authori[sz]e|i agree|i accept|consent|under penalty|on behalf|je certifie|j'atteste|je reconnais|j'accepte|consentement|certifico|atesto|reconozco|acepto|consentimiento|ich best[äa]tige|ich versichere|einwilligung|zustimmung|ich stimme/i,out=null;
  var marked=[].slice.call(document.querySelectorAll('[data-ook-form]'));
  var cookie=/\bcookies?\b|consent to service|\bconsent per service\b/i;
    var shown=function(e){if(!e) return false; var r=e.getBoundingClientRect(); return r.width>0&&r.height>0;};
  // A request the person may choose ("To withdraw consent", "To opt out of the sale"): a choice the app makes or leaves, never a statement to certify.
  var choice=/^\s*(i (want|would like|wish) to\s+)?(to\s+)?(withdraw (my )?consent|know|access|delete|be forgotten|correct|restrict|object|opt.?out|port|limit|request|receive a copy)\b/i;
  document.querySelectorAll('input[type=checkbox]').forEach(function(c){
    if(c.checked||out) return;
    var t='';
    if(c.id){var l=document.querySelector('label[for="'+c.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=c.closest('label'); if(p) t=p.innerText;}
    // Only a container that holds this box alone speaks for it: a whole form's text is not one box's label (cashmereai.com's unlabelled honeypot read its form's wording).
    if(!t){var n=c.parentElement; t=n&&n.querySelectorAll('input,select,textarea').length===1?n.innerText:'';}
    // "I am an authorized agent submitting on behalf of someone else" is an option for agents, not a requirement for the subject.
    // Only a box the person can see: one in a section the page hides (affinityanswers.com's EU requests, for a US visitor) is not asked of them. A styled box hides the
    // input itself and shows its label instead, so the label counts.
    var lab=c.id?document.querySelector('label[for="'+c.id+'"]'):null; if(!shown(c)&&!shown(lab)&&!shown(c.closest('label'))) return;
    // A bot trap ("honeypot") no person sees: moved off the page or hidden from assistive tech, with no visible label of its own (cashmereai.com's "botcheck").
    var r=c.getBoundingClientRect(), off=r.right<=0||r.bottom<=0||r.left>=window.innerWidth+1000||c.closest('[aria-hidden=true]');
    if(off&&!shown(lab)&&!shown(c.closest('label'))) return;
    if(choice.test(t)) return;
    // Only a box of a form the app is filling (`data-ook-form`, set when the forms are found): the rest of the page is not part of the request. A cookie
    // toggle is never one either: focus-usa.com's opt-out page (Complianz) lists every cookie service with an unticked "Consent to service google-adsense".
    if(marked.length&&!marked.some(function(f){return f.contains(c);})) return;
    if(cookie.test(t)||/accept-service|cookie/i.test(c.className||'')) return;
    if(re.test(t)&&!/\bagent\b|\bon behalf\b|representative|mandataire|repr[ée]sentant|au nom d|agente|representante|en nombre de|bevollm[äa]chtigt|im namen/i.test(t)) out=t.replace(/\s+/g,' ').trim().slice(0,140);});
  return out;})();
