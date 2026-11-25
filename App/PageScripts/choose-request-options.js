(function(token,ownerMayConfirm){
  var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return JSON.stringify({chosen:0,unresolved:[]});
  //#include ownership
  //#include bot-trap
  var label=function(e){var t='';
    if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=e.closest('label'); if(p) t=p.innerText;}
    if(!t){var lb=e.getAttribute('aria-labelledby'); if(lb) t=lb.split(/\s+/).map(function(id){var n=document.getElementById(id); return n?n.innerText:'';}).join(' ');}
    if(!t) t=e.getAttribute('aria-label')||e.getAttribute('value')||'';
    if(!t&&e.nextSibling&&e.nextSibling.textContent) t=e.nextSibling.textContent;
    return t.replace(/\s+/g,' ').trim();};
  var title=function(e){var t=''; if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
    if(!t){var p=e.closest('label'); if(p) t=p.innerText;} return (t||'').split(/\n/)[0].trim().slice(0,80);};
  var self=/\b(myself|me|my own|individual|consumer|resident|myself)\b/i, notSelf=/deceased|authori[sz]ed|agent|behalf|represent|business|company|employee|minor|child|another|someone else|other (person|individual|people)|third.party/i;
  var yes=/opt.?out|do not sell|don.?t sell|do not share|targeted advertis|cross-context|profil|delete|deletion|remove|erase|unsubscribe|limit the use/i;
  var no=/opt.?in|\baccess\b|know|correct|portab|copy of|subscribe\b(?!.*(out|unsub))|newsletter|receive/i;
  var optOutWord=/opt.?out|unsubscribe|do not sell|do not share/i, optInWord=/opt.?in|receive|sign me up/i;
  var ownerOK=ownerMayConfirm;
  var selfDecl=/\bi (confirm|verify|am|declare)\b.{0,100}\b(person|owner|me)\b.{0,60}(e-?mail|address|account|request|record|name|information)/i, notDecl=/penalty|perjury|agent|behalf|representative|authori[sz]ed to|attest|acknowledg|certif|terms|privacy policy|legal/i;
  var yesOrOptOut=function(t){return (yes.test(t)&&!no.test(t))||(optOutWord.test(t)&&!optInWord.test(t));};
  var isDecl=function(t){return ownerOK&&selfDecl.test(t)&&!notDecl.test(t);};
  var chosen=0, unresolved=[];
  var groups={};
  // Radios with no name (HubSpot's newer forms: datatowin.com's "Myself / Another Individual") are one question when they share a box: judged one by one,
  // each was chosen and the last one clicked ("Another Individual") won.
  var gi=0, keyOf=function(r){if(r.name) return 'n:'+r.name; var p=r.parentElement;
    while(p&&p!==f&&p.querySelectorAll('input[type=radio]').length<2) p=p.parentElement;
    if(!p) return 'g'+(gi++); if(!p.getAttribute('data-ook-rg')) p.setAttribute('data-ook-rg',String(gi++)); return 'c:'+p.getAttribute('data-ook-rg');};
  f.querySelectorAll('input[type=radio]').forEach(function(r){if(botTrap(r)) return; var k=keyOf(r); (groups[k]=groups[k]||[]).push(r);});
  // A question named only in code ("authorizedAgent", astoriacompany.com's No / Yes) is the same question.
  var agentQ=/authori[sz]ed[ _-]?agent|on behalf|acting as (an )?agency|submitting (this )?request (on|for)|are you (an? )?(agent|agency)/i;
  // "Are you submitting this request for yourself?" is the opposite question: Yes is the person's answer.
  var selfQ=/for (yourself|myself)|request for (yourself|yourself or)|are you (the )?(person|individual|consumer) (whose|this)/i;
  var removal=/\b(remov|delet|eras)\w*\b.{0,12}\b(my|me)\b.{0,12}\b(info|information|record|records|listing|profile|data)\b/i;
  Object.keys(groups).forEach(function(k){var rs=groups[k];
    // The page may start on its gentler choice ("Your privacy choices"); "Remove my information" is the one that takes a listing off.
    var rm=rs.filter(function(r){return removal.test(title(r));})[0]
      // Where only one can be chosen, deleting the data beats opting out of its sale.
      ||rs.filter(function(r){var t=title(r); return /\b(delet|eras)\w*\b/i.test(t)&&!no.test(t)&&!notSelf.test(t);})[0];
    if(rs.some(touched)||rs.some(autoDone)) return;
    // A choice of device ID types (GAID is Android's, IDFA is this phone's): this is an iPhone.
    var idfa=rs.filter(function(r){return /\bidfa\b/i.test(label(r));})[0];
    if(idfa){ if(!idfa.checked){markAuto(idfa); idfa.click(); if(!idfa.checked){idfa.checked=true; idfa.dispatchEvent(new Event('change',{bubbles:true}));} chosen++;} return; }
    // A choice of which identifier to give (privacy.sojern.com: Cookie, Mobile, Email, IP Address): the email, which the app has; the others belong to a device.
    var idKinds=rs.filter(function(r){return /^\s*(cookie|mobile|e-?mail|ip address|device id|maid)\b/i.test(label(r));}).length;
    var byEmail=idKinds>=3&&rs.filter(function(r){return /^\s*e-?mail\b/i.test(label(r));})[0];
    if(byEmail){ if(!byEmail.checked){markAuto(byEmail); byEmail.click(); if(!byEmail.checked){byEmail.checked=true; byEmail.dispatchEvent(new Event('change',{bubbles:true}));} chosen++;} return; }
    if(rm&&!rm.checked){markAuto(rm); rm.click(); if(!rm.checked){rm.checked=true; rm.dispatchEvent(new Event('change',{bubbles:true}));} chosen++; return;}
    if(rs.some(function(r){return r.checked;})) return;
    var pick=null;
    // "Are you an authorized agent / acting on behalf of someone?": the person is asking for themselves, so the answer is No.
    var ctx=((rs[0].closest('fieldset')||rs[0].closest('div')||{innerText:''}).innerText||'').slice(0,200)+' '+(rs[0].name||'');
    if(selfQ.test(ctx)){for(var q=0;q<rs.length&&!pick;q++){var ls=label(rs[q]); if(/^\s*(yes|myself|me|my own)\b/i.test(ls)&&!/agent|behalf|represent/i.test(ls)) pick=rs[q];}}
    if(!pick&&agentQ.test(ctx)){for(var q=0;q<rs.length&&!pick;q++){var lt=label(rs[q]); if(/^\s*(no|myself|me|my own|not an agent|individual)\b/i.test(lt)) pick=rs[q];}}
    // (Not a request choice: "Know what you hold about me" says "me" too, and was picked here ahead of the opt-out beside it.)
    for(var i=0;i<rs.length&&!pick;i++){var t=label(rs[i]); if(self.test(t)&&!notSelf.test(t)&&!yes.test(t)&&!no.test(t)) pick=rs[i];}
    // "Remove my information" (a person-search site taking a listing off) beats a plain "do not sell" choice beside it: it is the stronger opt-out.
    for(var i=0;i<rs.length&&!pick;i++){var ti=title(rs[i]); if(/\b(remov|delet|eras)\w*\b.{0,12}\b(my|me)\b.{0,12}\b(info|information|record|records|listing|profile|data)\b/i.test(ti)) pick=rs[i];}
    for(var i=0;i<rs.length&&!pick;i++){var t=label(rs[i]); if(yesOrOptOut(t)||isDecl(t)) pick=rs[i];}
    if(pick){markAuto(pick); pick.click(); if(!pick.checked){pick.checked=true; pick.dispatchEvent(new Event('change',{bubbles:true}));} chosen++;}
    else if(rs.some(function(r){return r.required;})) unresolved.push(label(rs[0])||k);});
  f.querySelectorAll('input[type=checkbox]').forEach(function(c){var t=label(c);
    if(c.checked||!t||touched(c)||autoDone(c)||botTrap(c)) return;
    // "I am submitting this request for myself" (next to "...on behalf of someone else"): the person is asking for themselves.
    if(/\b(for )?myself\b|\bfor me\b|\bmy own\b/i.test(t)&&!notSelf.test(t)){markAuto(c); c.click(); if(!c.checked){c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));} chosen++; return;}
    if(yesOrOptOut(t)||isDecl(t)){markAuto(c); c.click(); if(!c.checked){c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));} chosen++;}});
  f.querySelectorAll('select').forEach(function(s){if(botTrap(s)) return;
    var lf=s.id?document.querySelector('label[for="'+s.id+'"]'):null;
    var l=((s.name||'')+' '+(s.getAttribute('aria-label')||'')+' '+(lf?lf.innerText:'')).toLowerCase();
    var near=(s.closest('div')?s.closest('div').innerText:'').toLowerCase().slice(0,120);
    // A menu of states or countries is filled by value; a request-type menu that merely sits near the word "state" is not one.
    if(/state|country|province|region/.test(l)||s.options.length>=40) return;
    if((s.selectedIndex>0 && s.value)||touched(s)||autoDone(s)) return;
    var best=-1,bestScore=0;
    var isSelfQ=selfQ.test(l+' '+near), isAgentQ=!isSelfQ&&agentQ.test(l+' '+near);
    for(var i=0;i<s.options.length;i++){var t=s.options[i].text; var sc=0;
      if(isSelfQ&&/^\s*(yes|myself|me|my own)\b/i.test(t)&&!/agent|behalf|represent/i.test(t)) sc=5;
      if(isAgentQ&&/^\s*(no|myself|me|my own|not an agent|individual)\b/i.test(t)) sc=5;
      if(/opt.?out|do not sell|do not share|unsubscribe/i.test(t)) sc=2;
      if(/delet|remov|eras/i.test(t)) sc=Math.max(sc,3);          // deleting the data beats opting out of its sale
      if(/\b(consumer|individual|personal|myself|resident|person|the (person|individual|subject)|data subject|yourself|owner|me)\b/i.test(t)&&!/business|agent|deceased|on behalf|representative/i.test(t)) sc=Math.max(sc,1);
      // "Relationship with us" menus: a person who is only asking to be removed is a consumer, not a customer, employee or partner.
      if(/relationship|how do we know|are you a|i am/i.test(l+' '+near)&&/\b(consumer|individual|none of the above|not a (customer|client|user)|no relationship|general public|just a consumer|other)\b/i.test(t)&&!/business|agent|employee|partner|client of|vendor/i.test(t)) sc=Math.max(sc,1);
      if(/access|know|correct|update|portab/i.test(t)) sc=0;
      if(sc>bestScore){bestScore=sc;best=i;}}
    // "I am a (an)": Customer / Authorized Agent (blueaction.io). When every answer but one is someone acting for another person, the one left is the person's own.
    if(best<0&&/\b(i am|are you|requester|requestor|who (is|are))\b/i.test(l+' '+near)){
      var own=[]; for(var k2=0;k2<s.options.length;k2++){var tk=(s.options[k2].text||'').trim(); if(tk&&s.options[k2].value!==''&&!/agent|behalf|represent|deceased|parent|guardian|attorney|business/i.test(tk)) own.push(k2);}
      if(own.length===1) best=own[0];}
    var placeholder=s.selectedIndex<=0;
    if(best>=0&&placeholder){markAuto(s); s.selectedIndex=best; s.dispatchEvent(new Event('change',{bubbles:true})); s.dispatchEvent(new Event('input',{bubbles:true})); chosen++;}
    else if(s.required&&placeholder) unresolved.push((near.split('\n')[0]||l||'a menu').slice(0,60));});
  return JSON.stringify({chosen:chosen,unresolved:unresolved});})
