(function(){
  var text=(document.body?document.body.innerText:'').toLowerCase();
  // A check the person already passed leaves a token behind; the page's own "please wait for the anti-spam check" line (from an early press) can stay on screen.
  var solved=[].some.call(document.querySelectorAll('input[name="cf-turnstile-response"],textarea[name="g-recaptcha-response"],textarea[name="h-captcha-response"]'),function(e){return !!e.value;});
  // The page says its reCAPTCHA refused the send (a score-based one rejects scripted presses): only the person's own tap on the page's button can get past it.
  if(/recaptcha[^.]{0,40}(missing|invalid|failed|expired|could not be verified)|failed (the )?recaptcha/.test(text)) return 'a reCAPTCHA that rejected the automatic send';
  if(!solved&&/anti-?spam check|wait for the (anti-?spam|security) check|confirm you are human|i.?m not a robot|select all (the )?(images|squares)|prove you.?re (not a robot|human)|are you a robot|verify you are human|are you a human|checking your browser|just a moment|security challenge|performing security verification|v[ée]rifiez que vous [êe]tes humain|v[ée]rification de s[ée]curit[ée]|verifica que eres humano|comprobaci[oó]n de seguridad|best[äa]tigen sie, dass sie ein mensch|sicherheits[üu]berpr[üu]fung/.test(text)) return 'a human check';
  // A picture code to type (OneTrust's webforms, blackbaud.com): an empty box named for a captcha beside its picture. Only the person can read it.
  var cap=[].slice.call(document.querySelectorAll('input')).filter(function(e){var r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&!e.value&&
    /captcha/i.test([e.name,e.id,e.placeholder,e.getAttribute('aria-label')].join(' '))&&!/g-recaptcha|h-captcha|turnstile/i.test(e.name||'');})[0];
  if(cap){for(var p=cap.parentElement,d=0;p&&d<4;p=p.parentElement,d++){if(p.querySelector('img,canvas,svg[class*=captcha i]')) return 'a captcha code to type';}}
  var ts=document.querySelector('.cf-turnstile,[class*="turnstile" i],[id*="turnstile" i]');
  if(ts){var tr=ts.getBoundingClientRect(),tt=document.querySelector('input[name="cf-turnstile-response"]'); if(tr.width>0&&tr.height>0&&(!tt||!tt.value)) return 'a Cloudflare check';}
  var frames=document.querySelectorAll('iframe');
  for(var i=0;i<frames.length;i++){var f=frames[i],src=f.src||'',r=f.getBoundingClientRect();
    if(r.width<40||r.height<40) continue;
    if(f.closest&&f.closest('.grecaptcha-badge')) continue;
    if(/recaptcha\/(api2|enterprise)\/bframe/.test(src)) return 'a reCAPTCHA puzzle';
    if(/recaptcha\/(api2|enterprise)\/anchor/.test(src)){var ta=document.querySelector('textarea[name="g-recaptcha-response"]'); if(!ta||!ta.value) return 'a reCAPTCHA checkbox';}
    if(/hcaptcha\.com/.test(src)){var h=document.querySelector('textarea[name="h-captcha-response"]'); if(!h||!h.value) return 'an hCaptcha';}
    if(/challenges\.cloudflare\.com/.test(src)){var t=document.querySelector('input[name="cf-turnstile-response"]'); if(!t||!t.value) return 'a Cloudflare check';}
  }
  return null;})();
