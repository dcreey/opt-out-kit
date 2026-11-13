var P={};
P.marketing=new RegExp("subscribe|free trial|get started|sign.?up|log.?in|sign.?in|search|book a|demo|contact us|get in touch|newsletter|join|download|add another","i");
P.optOut=new RegExp("opt.?(me.?)?out|do not sell|don.?t sell|do-not-sell|privacy|delete|deletion|remove|erase|request|rights|unsubscribe|suppress|removal","i");
P.signup=new RegExp("subscribe|newsletter|sign.?up|register(?!ed)|create (an? )?account|\\bjoin\\b|waitlist|\\bdemo\\b|free trial|get started|contact sales|talk to|activation|log.?in|sign.?in|shortlist|get in touch|send message|contact us|request a (quote|call)|book a|get my [a-z ]*(guide|report)|show my report|free (guide|report)","i");
P.signupContext=new RegExp("newsletter|(?<!un)subscrib(e|ing|ed)|receive (updates|news|emails?)|and receive|in your inbox|to your inbox|stay (updated|in the loop)|get (the )?(latest|updates)|join our|sign.?up for|free trial|updates (and|&) insights|delivered to|receive (communications|marketing)|agree to receive","i");
P.strongOptOut=new RegExp("opt.?(me.?)?out|do not sell|don.?t sell|privacy (request|choices|rights)|delete my|deletion request|erasure|data subject|remove (me|my)","i");
P.businessField=new RegExp("(business|work|corporate|company) e-?mail|\\bindustry\\b|job (title|function|role)|company size|number of employees","i");
P.notOptOut=new RegExp("get a quote|request a (consultation|quote)|consultation|speak with|schedule a|what to report|contact(ing)? us|thank you for contacting|send (us )?a? ?message|put some numbers|confirm you are human|verify you are human","i");
P.passwordWord=new RegExp("pass\\s*word|passwort|contrase","i");
P.maskedData=new RegExp("ssn|social|last (4|four)|phone|digit|\\bpin\\b|\\btel\\b|mobile","i");
P.navigationToggle=new RegExp("navigation|\\bmenu\\b|submenu|hamburger","i");
P.deceasedForm=new RegExp("deceased|decedent|late (husband|wife|mother|father)|passed away","i");
P.identity=new RegExp("first|last|name|email|e-mail|address|zip|postal|phone|city","i");
P.ownWords=new RegExp("opt.?(me.?)?out|do not sell|unsubscribe|delete|remove|erase","i");
var has=function(re,s){return re.test(s||'')};
var vis=function(e){var r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'};
var label=function(e){var t='';
 if(e.id){var l=document.querySelector('label[for="'+e.id+'"]');if(l)t=l.innerText}
 if(!t){var p=e.closest('label');if(p)t=p.innerText}
 if(!t){var lb=e.getAttribute('aria-labelledby');if(lb)t=lb.split(/\s+/).map(function(id){var n=document.getElementById(id);return n?n.innerText:''}).join(' ')}
 if(!t)t=e.getAttribute('aria-label')||e.placeholder||e.getAttribute('title')||'';
 if(!t&&e.previousElementSibling)t=e.previousElementSibling.innerText||'';
 if(!t&&e.parentElement)t=(e.parentElement.innerText||'').slice(0,60);
 return t.replace(/\s+/g,' ').trim().slice(0,90)};
var ctxEl=function(e){var n=e;for(var i=0;i<8&&n&&n!==document.body;i++,n=n.parentElement){var t=(n.innerText||'').replace(/\s+/g,' ').trim();if(t.length>=25&&t.length<=700)return n}return e.parentElement||e};
var ftype=function(e){var t=e.tagName.toLowerCase();return t==='select'?'select':(t==='textarea')?'textarea':(e.type||'text')};
var forms=[],els=[];var headOf=function(f){var n=f;for(var i=0;i<6&&n&&n!==document.body;i++,n=n.parentElement){var p=n.previousElementSibling;for(var j=0;j<8&&p;j++,p=p.previousElementSibling){if(/^H[1-6]$/.test(p.tagName))return (p.innerText||'').replace(/\s+/g,' ').trim().slice(0,80);var h=p.querySelector&&p.querySelector('h1,h2,h3,h4,h5,h6');if(h)return (h.innerText||'').replace(/\s+/g,' ').trim().slice(0,80)}}return ''};
document.querySelectorAll('form').forEach(function(f,i){els.push(f);var fl=[];f.querySelectorAll('input,select,textarea').forEach(function(e){var ty=ftype(e);if(['hidden','submit','button','image','reset'].indexOf(ty)>=0)return;var l=label(e);fl.push({type:ty,name:e.name||e.id||'',label:l,required:!!e.required||/\*/.test(l),visible:vis(e),disabled:!!e.disabled,val:(ty==='checkbox'||ty==='radio')?'':(e.value||'')})});
 var bt=[];f.querySelectorAll('button,input[type=submit],input[type=button],[role=button]').forEach(function(b){if(vis(b))bt.push(((b.innerText||b.value||'')+'').trim().slice(0,60))});
 forms.push({fields:fl,buttons:bt,text:(f.innerText||'').replace(/\s+/g,' ').trim().slice(0,240),ctx:(ctxEl(f).innerText||'').replace(/\s+/g,' ').trim().slice(0,600),head:headOf(f)})});
var loose=[].slice.call(document.querySelectorAll('input,select,textarea')).filter(function(e){return !e.closest('form')&&['hidden','submit','button','image','reset','search'].indexOf(e.type)<0&&vis(e)});
if(loose.length){var box=ctxEl(loose[0]);els.push(box);var lb=[];box.querySelectorAll('button,input[type=submit],[role=button]').forEach(function(b){if(vis(b))lb.push(((b.innerText||b.value||'')+'').trim().slice(0,60))});
 forms.push({loose:1,fields:loose.map(function(e){var ty=ftype(e);return {type:ty,name:e.name||e.id||'',label:label(e),required:!!e.required,visible:true,disabled:!!e.disabled,val:e.value||''}}),buttons:lb.slice(0,12),text:(box.innerText||'').replace(/\s+/g,' ').trim().slice(0,240),ctx:(box.innerText||'').replace(/\s+/g,' ').trim().slice(0,600),head:headOf(box)})}
var pageCtx=(location.pathname+' '+document.title).slice(0,300);
var score=function(f){var fields=f.fields.filter(function(x){return x.visible&&['hidden','submit','button','image','password'].indexOf(x.type)<0});
 if(!fields.length)return -100;
 if(fields.some(function(x){return x.type==='email'&&x.disabled}))return -100;
 var buttons=f.buttons.join(' '),heading=f.text;
 if(has(P.notOptOut,buttons+' '+heading.slice(0,200)+' '+(f.head||''))&&!has(P.strongOptOut,heading+' '+buttons+' '+(f.head||'')))return -100;
 if(f.fields.some(function(x){return x.visible&&has(P.passwordWord,x.label+' '+x.name)&&!has(P.maskedData,x.label+' '+x.name)}))return -100;
 if(fields.every(function(x){return ['checkbox','radio'].indexOf(x.type)>=0&&has(P.navigationToggle,x.label+' '+x.name)}))return -100;
 if(!f.buttons.length&&fields.every(function(x){return x.type==='select'})&&!has(P.optOut,fields.map(function(x){return x.label+' '+x.name}).join(' ')+' '+heading+' '+(f.head||'')))return -100;
 if(has(P.signup,buttons+' '+heading.slice(0,200))&&!has(P.optOut,buttons)&&!has(P.strongOptOut,heading))return -100;
 var ctx=f.ctx||'';
 if(fields.length<=3&&has(P.signupContext,ctx)&&!has(P.strongOptOut,heading+' '+buttons))return -100;
 if(fields.some(function(x){return has(P.businessField,x.label+' '+x.name)})&&!has(P.strongOptOut,heading+' '+buttons)&&!has(P.optOut,buttons))return -100;
 if(fields.length<=1&&!has(P.optOut,buttons+' '+heading)&&!has(P.strongOptOut,ctx))return -100;
 var s=0;if(has(P.optOut,buttons))s+=4;if(has(P.optOut,heading))s+=2;
 if(has(P.deceasedForm,heading+' '+buttons+' '+pageCtx))s-=8;
 if(has(P.marketing,buttons))s-=6;if(has(P.marketing,heading)&&!has(P.optOut,buttons))s-=3;
 if(has(P.optOut,pageCtx))s+=3;
 s+=Math.min(4,fields.filter(function(x){return has(P.identity,x.label+' '+x.name)}).length);
 if(fields.some(function(x){return x.type==='email'||/e-?mail/i.test(x.label+x.name)}))s+=2;
 if(fields.some(function(x){return x.type==='password'}))s-=8;return s};
var sc=forms.map(score),bi=-1,bs=-1000;sc.forEach(function(s,i){if(s>bs){bs=s;bi=i}});
var T=(document.body&&document.body.innerText||'');
var out={u:location.host+location.pathname,t:document.title.slice(0,50),n:forms.length,sc:sc.join(',')};
out.flags=[];
if(/just a moment|attention required|access denied|are you a robot|verify you are human/i.test(document.title+' '+T.slice(0,300)))out.flags.push('BLOCKED');
if(/404|not found|page not found/i.test(document.title))out.flags.push('404');
if(document.querySelector('iframe[src*=recaptcha],.g-recaptcha,iframe[src*=hcaptcha],.h-captcha,iframe[src*=turnstile],.cf-turnstile'))out.flags.push('CAPTCHA');
if(bs>=3){var b=forms[bi];document.querySelectorAll('[data-ookpick]').forEach(function(x){x.removeAttribute('data-ookpick')});els[bi].setAttribute('data-ookpick','1');out.head=(function(){var n=els[bi];for(var i=0;i<6&&n;i++,n=n.parentElement){var p=n.previousElementSibling;for(var j=0;j<8&&p;j++,p=p.previousElementSibling){if(/^H[1-6]$/.test(p.tagName))return (p.innerText||'').trim().slice(0,80);var h=p.querySelector&&p.querySelector('h1,h2,h3,h4,h5');if(h)return (h.innerText||'').trim().slice(0,80)}}return ''})();out.ftext=b.text.slice(0,160);out.pick=1;out.fields=b.fields.filter(function(x){return x.visible}).map(function(x){return (x.label||x.name).slice(0,22)+':'+x.type+(x.required?'*':'')+(x.disabled?'(DIS)':'')+(x.val&&x.type!=='select'?'[='+x.val.slice(0,12)+']':'')}).join('; ');out.btn=b.buttons.slice(0,3).join('/')}
else{out.pick=0;out.hint=forms.slice(0,3).map(function(f){return f.fields.filter(function(x){return x.visible}).length+'f:'+f.buttons.slice(0,2).join('/')}).join(' | ');var nb=[].slice.call(document.querySelectorAll('button,a,[role=button]')).filter(function(e){return vis(e)&&/^(next|continue|start|get started|begin|submit a request|make a request)/i.test((e.innerText||'').trim())}).length;if(nb)out.flags.push('INTRO-BTN')}
out.iframes=document.querySelectorAll('iframe').length;
JSON.stringify(out)
