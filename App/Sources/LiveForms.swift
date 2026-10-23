import Foundation
import WebKit
import OptOutKitCore

/// What is really on the page the person would see: the forms, their fields and their buttons, read from the live page after scripts have run
/// (not from a copy of the HTML fetched earlier). The crawler's stored form is only a hint; this is what the run fills in and sends.
struct LiveField: Decodable, Equatable {
    var token: String           // data-ook attribute the page JS put on the element, so it can be found again whatever its name is
    var name: String
    var type: String
    var label: String
    var required: Bool
    var visible: Bool
}

struct LiveForm: Decodable, Equatable {
    var token: String
    var action: String
    var method: String
    var visible: Bool
    var fields: [LiveField]
    var buttons: [String]
    var text: String

    /// The form as the filler understands it. Each field is named by its token, and its label carries the page's own name for it, so the
    /// same synonyms that read a stored form read this one.
    func asOptOutForm(page: URL) -> OptOutForm {
        OptOutForm(page: page, method: method.lowercased(), action: URL(string: action),
                   fields: fields.filter { $0.visible }.map { FormField(type: $0.type, name: $0.token, label: ($0.label + " " + $0.name).trimmingCharacters(in: .whitespaces)) }, hops: 1)
    }
}

enum LiveFormPicker {
    private static let marketing = try! NSRegularExpression(pattern: "subscribe|free trial|get started|sign.?up|log.?in|sign.?in|search|book a|demo|contact us|get in touch|newsletter|join|download|add another", options: .caseInsensitive)
    private static let optOut = try! NSRegularExpression(pattern: "opt.?out|do not sell|don.?t sell|do-not-sell|privacy|delete|deletion|remove|erase|request|rights|unsubscribe|suppress|removal", options: .caseInsensitive)
    private static let identity = try! NSRegularExpression(pattern: "first|last|name|email|e-mail|address|zip|postal|phone|city", options: .caseInsensitive)

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// How likely a form is the opt-out form: opt-out wording and several identity fields count for it, marketing wording against it.
    static func score(_ f: LiveForm, pageContext: String = "") -> Int {
        guard f.visible else { return -100 }
        let fields = f.fields.filter { $0.visible && !["hidden", "submit", "button", "image", "password"].contains($0.type) }
        guard !fields.isEmpty else { return -100 }
        let buttons = f.buttons.joined(separator: " ")
        let heading = f.text
        var s = 0
        if has(optOut, buttons) { s += 4 }
        if has(optOut, heading) { s += 2 }
        if has(marketing, buttons) { s -= 6 }
        if has(marketing, heading) && !has(optOut, buttons) { s -= 3 }
        if has(optOut, pageContext) { s += 3 }
        s += min(4, fields.filter { has(identity, $0.label + " " + $0.name) }.count)
        if fields.contains(where: { $0.type == "email" || has(try! NSRegularExpression(pattern: "e-?mail", options: .caseInsensitive), $0.label + $0.name) }) { s += 2 }
        if fields.contains(where: { $0.type == "password" }) { s -= 8 }
        return s
    }

    /// The best candidate, or nil when nothing on the page looks like an opt-out form.
    static func pick(_ forms: [LiveForm], pageContext: String = "") -> LiveForm? {
        let ranked = forms.map { ($0, score($0, pageContext: pageContext)) }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 3 else { return nil }
        return best.0
    }
}

extension WebViewSession {
    /// Denies cookie and consent prompts that sit over the page. They load late, so this is tried more than once. Never accepts.
    func denyCookies() async -> String? {
        let js = #"""
        (function(){
          var docs=[document]; document.querySelectorAll('iframe').forEach(function(f){try{if(f.contentDocument) docs.push(f.contentDocument);}catch(e){}});
          var known=['#onetrust-reject-all-handler','#axeptio_btn_dismiss','#axeptio_btn_dismiss_all','#CybotCookiebotDialogBodyButtonDecline','button#truste-consent-required','.cc-deny','[data-cookiefirst-action=reject]',
                     '.osano-cm-denyAll','#didomi-notice-disagree-button','button[aria-label*="Reject" i]','.cookie-reject','#cookie-reject','.ot-pc-refuse-all-handler'];
          for(var di=0;di<docs.length;di++){for(var i=0;i<known.length;i++){var e=docs[di].querySelector(known[i]); if(e&&e.offsetParent!==null){e.click();return known[i];}}}
          var re=/^\s*(reject( all)?( cookies| non-essential( cookies)?)?|deny( all)?|decline( all)?|i do not accept( cookies)?|only (necessary|essential)( cookies)?|necessary( cookies)? only|no,? thanks|disagree|refuse( all)?|do not accept|tout refuser|rechazar todo|alle ablehnen)\s*$/i;
          for(var dj=0;dj<docs.length;dj++){
            var els=docs[dj].querySelectorAll('button,a,[role=button],input[type=button],input[type=submit],div,span,li');
            for(var j=0;j<els.length;j++){var el=els[j],t=(el.innerText||el.value||'').trim();
              if(!re.test(t)||t.length>40) continue; if(el.children.length>1) continue;
              var r=el.getBoundingClientRect(); if(r.width<=0||r.height<=0) continue;
              el.click(); return t;}}
          return null;})();
        """#
        return (try? await webView.evaluateJavaScript(js)) as? String
    }

    /// Every visible form with its fields. Each form and field gets a `data-ook` token so later steps find the same element.
    func discoverForms() async -> [LiveForm] {
        let js = #"""
        (function(){
          var vis=function(e){var r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
          var label=function(e){var t='';
            if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
            if(!t){var p=e.closest('label'); if(p) t=p.innerText;}
            if(!t) t=e.getAttribute('aria-label')||e.placeholder||e.getAttribute('title')||'';
            if(!t&&e.previousElementSibling) t=e.previousElementSibling.innerText||'';
            if(!t&&e.parentElement) t=(e.parentElement.innerText||'').slice(0,60);
            return t.replace(/\s+/g,' ').trim().slice(0,90);};
          var out=[];
          document.querySelectorAll('form').forEach(function(f,i){
            var ftoken='f'+i; f.setAttribute('data-ook-form',ftoken);
            var fields=[]; f.querySelectorAll('input,select,textarea').forEach(function(e,j){
              var type=e.tagName.toLowerCase()==='select'?'select':(e.tagName.toLowerCase()==='textarea'?'textarea':(e.type||'text'));
              if(['hidden','submit','button','image','reset'].indexOf(type)>=0) return;
              var token=ftoken+'-'+j; e.setAttribute('data-ook',token);
              var l=label(e);
              fields.push({token:token,name:e.name||e.id||'',type:type,label:l,required:!!e.required||/\*/.test(l),visible:vis(e)});});
            var buttons=[]; f.querySelectorAll('button,input[type=submit],input[type=button],[role=button]').forEach(function(b){
              if(vis(b)) buttons.push(((b.innerText||b.value||'')+'').trim().slice(0,60));});
            out.push({token:ftoken,action:f.getAttribute('action')||'',method:f.method||'get',visible:vis(f),fields:fields,buttons:buttons,
                      text:(f.innerText||'').replace(/\s+/g,' ').trim().slice(0,240)});});
          // Single-page request portals put their inputs on the page without a <form>. Treat the loose inputs as one form.
          var loose=[].slice.call(document.querySelectorAll('input,select,textarea')).filter(function(e){
            return !e.closest('form')&&['hidden','submit','button','image','reset','search'].indexOf(e.type)<0&&vis(e);});
          if(loose.length>=2&&document.body){
            document.body.setAttribute('data-ook-form','fx'); var lf=[];
            loose.forEach(function(e,j){var type=e.tagName.toLowerCase()==='select'?'select':(e.tagName.toLowerCase()==='textarea'?'textarea':(e.type||'text'));
              var token='fx-'+j; e.setAttribute('data-ook',token); var l=label(e);
              lf.push({token:token,name:e.name||e.id||'',type:type,label:l,required:!!e.required||/\*/.test(l),visible:true});});
            var lb=[]; document.querySelectorAll('button,input[type=submit],[role=button]').forEach(function(b){if(vis(b)) lb.push(((b.innerText||b.value||'')+'').trim().slice(0,60));});
            out.push({token:'fx',action:'',method:'post',visible:true,fields:lf,buttons:lb.slice(0,12),text:(document.body.innerText||'').replace(/\s+/g,' ').trim().slice(0,240)});}
          return JSON.stringify(out);})();
        """#
        guard let json = (try? await webView.evaluateJavaScript(js)) as? String, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LiveForm].self, from: data)) ?? []
    }

    /// Fills the values the plan chose, finding each field by its token.
    /// Fills the form; menus that fill in after another choice (a state list that waits for the country) get a second pass.
    func fillLive(_ values: [FieldValue]) async -> (filled: Int, unmatchedRequired: [String]) {
        let first = await fillLiveOnce(values)
        guard !first.unmatchedRequired.isEmpty else { return first }
        try? await Task.sleep(nanoseconds: 900_000_000)
        return await fillLiveOnce(values)
    }

    private func fillLiveOnce(_ values: [FieldValue]) async -> (filled: Int, unmatchedRequired: [String]) {
        let normal = values.filter { $0.type != FormFiller.confirmIdentityType }
        if values.contains(where: { $0.type == FormFiller.confirmIdentityType }) { _ = await tickIdentityBoxes() }
        let payload = normal.map { ["name": $0.name, "candidates": $0.candidates] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return (0, []) }
        let js = #"""
        (function(values){var filled=0, unmatched=[];
          function setValue(el,v){var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
            var d=Object.getOwnPropertyDescriptor(proto,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
            el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));}
          values.forEach(function(v){var el=document.querySelector('[data-ook="'+v.name+'"]'); if(!el) return;
            if(el.tagName==='SELECT'){var done=false;
              for(var c=0;c<v.candidates.length&&!done;c++){var want=(v.candidates[c]||'').toLowerCase();
                for(var i=0;i<el.options.length;i++){var o=el.options[i];
                  if(o.value.toLowerCase()===want||o.text.trim().toLowerCase()===want){el.value=o.value;done=true;break;}}}
              if(!done&&/state|province|region/i.test((el.name||'')+' '+(el.id||'')+' '+(el.getAttribute('aria-label')||''))){
                // No match for the person's state: take "Other US state" / "Other" / "Not listed" when the menu has one.
                for(var k=0;k<el.options.length&&!done;k++){var tx=el.options[k].text.trim();
                  if(/^(other( u\.?s\.?( state)?s?)?|other state|not listed|outside (the )?u\.?s)/i.test(tx)){el.value=el.options[k].value;done=true;}}}
              if(done){el.dispatchEvent(new Event('change',{bubbles:true}));filled++;}
              else if(el.required||/\*|required/i.test((el.getAttribute('aria-label')||'')+(el.closest('label')?el.closest('label').innerText:'')+(el.id&&document.querySelector('label[for="'+el.id+'"]')?document.querySelector('label[for="'+el.id+'"]').innerText:''))) unmatched.push((v.candidates[0]||'')+'');
            } else if(v.candidates.length&&v.candidates[0]!==null){setValue(el,v.candidates[0]);filled++;}});
          return JSON.stringify({filled:filled,unmatched:unmatched});})(\#(json));
        """#
        guard let out = (try? await webView.evaluateJavaScript(js)) as? String, let d = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (0, []) }
        return (obj["filled"] as? Int ?? 0, obj["unmatched"] as? [String] ?? [])
    }

    /// Chooses, inside one form, the options an opt-out needs: "this request is for myself", the opt-out and deletion choices, and a
    /// request-type menu. It never ticks access, correction or marketing choices, and never picks "authorized agent" or "deceased".
    /// Returns what it chose, and the names of required choices it could not make.
    func chooseRequestOptions(form token: String, ownerMayConfirm: Bool = false) async -> (chosen: Int, unresolved: [String]) {
        let js = #"""
        (function(token){
          var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return JSON.stringify({chosen:0,unresolved:[]});
          var label=function(e){var t='';
            if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
            if(!t){var p=e.closest('label'); if(p) t=p.innerText;}
            if(!t) t=e.getAttribute('aria-label')||e.getAttribute('value')||'';
            if(!t&&e.nextSibling&&e.nextSibling.textContent) t=e.nextSibling.textContent;
            return t.replace(/\s+/g,' ').trim();};
          var self=/\b(myself|me|my own|individual|consumer|resident|myself)\b/i, notSelf=/deceased|authori[sz]ed|agent|behalf|represent|business|company|employee|minor|child/i;
          var yes=/opt.?out|do not sell|don.?t sell|do not share|targeted advertis|cross-context|profil|delete|deletion|remove|erase|unsubscribe|limit the use/i;
          var no=/opt.?in|\baccess\b|know|correct|portab|copy of|subscribe\b(?!.*(out|unsub))|newsletter|receive/i;
          var optOutWord=/opt.?out|unsubscribe|do not sell|do not share/i, optInWord=/opt.?in|receive|sign me up/i;
          var ownerOK=\#(ownerMayConfirm ? "true" : "false");
          var selfDecl=/\bi (confirm|verify|am|declare)\b.{0,100}\b(person|owner|me)\b.{0,60}(e-?mail|address|account|request|record|name|information)/i, notDecl=/penalty|perjury|agent|behalf|representative|authori[sz]ed to|attest|acknowledg|certif|terms|privacy policy|legal/i;
          var yesOrOptOut=function(t){return (yes.test(t)&&!no.test(t))||(optOutWord.test(t)&&!optInWord.test(t));};
          var isDecl=function(t){return ownerOK&&selfDecl.test(t)&&!notDecl.test(t);};
          var chosen=0, unresolved=[];
          var groups={};
          f.querySelectorAll('input[type=radio]').forEach(function(r){(groups[r.name||('g'+Math.random())]=groups[r.name||'']||[]).push(r);});
          Object.keys(groups).forEach(function(k){var rs=groups[k]; if(rs.some(function(r){return r.checked;})) return;
            var pick=null;
            for(var i=0;i<rs.length&&!pick;i++){var t=label(rs[i]); if(self.test(t)&&!notSelf.test(t)) pick=rs[i];}
            for(var i=0;i<rs.length&&!pick;i++){var t=label(rs[i]); if(yesOrOptOut(t)||isDecl(t)) pick=rs[i];}
            if(pick){pick.click(); if(!pick.checked){pick.checked=true; pick.dispatchEvent(new Event('change',{bubbles:true}));} chosen++;}
            else if(rs.some(function(r){return r.required;})) unresolved.push(label(rs[0])||k);});
          f.querySelectorAll('input[type=checkbox]').forEach(function(c){var t=label(c);
            if(c.checked||!t) return; if(yesOrOptOut(t)||isDecl(t)){c.click(); if(!c.checked){c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));} chosen++;}});
          f.querySelectorAll('select').forEach(function(s){
            var l=((s.name||'')+' '+(s.getAttribute('aria-label')||'')).toLowerCase();
            var near=(s.closest('div')?s.closest('div').innerText:'').toLowerCase().slice(0,120);
            if(/state|country|province|region/.test(l)||/state of|country/.test(near)) return;
            if(s.selectedIndex>0 && s.value) return;
            var best=-1,bestScore=0;
            for(var i=0;i<s.options.length;i++){var t=s.options[i].text; var sc=0;
              if(/opt.?out|do not sell|do not share|unsubscribe/i.test(t)) sc=3;
              if(/delet|remov|eras/i.test(t)) sc=Math.max(sc,2);
              if(/\b(consumer|individual|myself|resident|person)\b/i.test(t)&&!/business|agent|deceased/i.test(t)) sc=Math.max(sc,1);
              if(/access|know|correct|update|portab/i.test(t)) sc=0;
              if(sc>bestScore){bestScore=sc;best=i;}}
            var placeholder=s.selectedIndex<=0;
            if(best>=0&&placeholder){s.selectedIndex=best; s.dispatchEvent(new Event('change',{bubbles:true})); s.dispatchEvent(new Event('input',{bubbles:true})); chosen++;}
            else if(s.required&&placeholder) unresolved.push((near.split('\n')[0]||l||'a menu').slice(0,60));});
          return JSON.stringify({chosen:chosen,unresolved:unresolved});})(\#(Self.liveLiteral(token)));
        """#
        guard let json = (try? await webView.evaluateJavaScript(js)) as? String, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, []) }
        return (obj["chosen"] as? Int ?? 0, obj["unresolved"] as? [String] ?? [])
    }

    /// Presses the chosen form's own send button, whatever it says ("Opt me out", "Submit request"); never one that says agree, accept or cancel.
    func pressLiveSubmit(form token: String) async -> Bool {
        let js = #"""
        (function(token){var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return false;
          var bad=/agree|accept|cancel|clear|reset|back|add another|^\+|subscribe/i;
          var bs=[].slice.call(f.querySelectorAll('button,input[type=submit],input[type=button],[role=button]')).filter(function(b){
            var t=((b.innerText||b.value||'')+'').trim(); var r=b.getBoundingClientRect(); return r.width>0&&r.height>0&&!bad.test(t);});
          var pick=null;
          for(var i=0;i<bs.length&&!pick;i++){var ty=(bs[i].getAttribute('type')||'').toLowerCase(); if(ty==='submit') pick=bs[i];}
          for(var i=0;i<bs.length&&!pick;i++){if(/submit|send|opt|continue|request|go|confirm|remove|delete/i.test((bs[i].innerText||bs[i].value||''))) pick=bs[i];}
          if(!pick&&bs.length) pick=bs[bs.length-1];
          if(pick){pick.scrollIntoView({block:'center'}); pick.click(); return true;}
          if(f.requestSubmit){f.requestSubmit(); return true;} f.submit(); return true;})(\#(Self.liveLiteral(token)));
        """#
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    /// The page's address path and title: a form on a page about opting out is more likely the opt-out form.
    func pageContext() async -> String {
        ((try? await webView.evaluateJavaScript("location.pathname + ' ' + document.title")) as? String) ?? ""
    }

    /// A visible, empty text box that asks for a code ("Captcha", "Security code"): the person types it, and the form is not sent until it is filled.
    func emptyCodeField() async -> Bool {
        let js = #"""
        (function(){var re=/captcha|security.?code|verification.?code|enter the (code|text|characters)|type the (code|characters)/i;
          var els=document.querySelectorAll('input[type=text],input:not([type]),input[type=tel],input[type=number]');
          for(var i=0;i<els.length;i++){var e=els[i],r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0) continue;
            var l=(e.name||'')+' '+(e.id||'')+' '+(e.placeholder||'')+' '+(e.getAttribute('aria-label')||'');
            if(e.id){var lb=document.querySelector('label[for="'+e.id+'"]'); if(lb) l+=' '+lb.innerText;}
            if(re.test(l)&&!e.value) return true;}
          return false;})();
        """#
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    /// Whether the chosen form is still on the page and visible, and the page's address.
    func formState(_ token: String) async -> (visible: Bool, url: String) {
        let js = "(function(){var f=document.querySelector('[data-ook-form=\"\(token)\"]'); var v=false; if(f){var r=f.getBoundingClientRect(),s=getComputedStyle(f); v=r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';} return JSON.stringify({v:v,u:location.href});})();"
        guard let out = (try? await webView.evaluateJavaScript(js)) as? String, let d = out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (true, "") }
        return (o["v"] as? Bool ?? true, o["u"] as? String ?? "")
    }

    /// Hides what is left of a cookie or consent overlay that would not be dismissed, so it does not cover the form or the result.
    /// (It consents to nothing; it only stops covering the page.)
    func hideConsentOverlays() async {
        let js = #"""
        (function(){var n=0; document.querySelectorAll('div,section,aside,dialog,[role=dialog]').forEach(function(e){
          var s=getComputedStyle(e); if(s.position!=='fixed'&&s.position!=='sticky') return;
          var t=(e.innerText||'').toLowerCase(); if(t.length>1500) return;
          if(/cookie|consent|gdpr|your privacy choices?:? we use|tracking technolog/.test(t)&&!e.querySelector('form')){e.style.setProperty('display','none','important');n++;}});
          document.querySelectorAll('iframe').forEach(function(f){var s=getComputedStyle(f); var txt='';
            try{txt=((f.contentDocument&&f.contentDocument.body&&f.contentDocument.body.innerText)||'').toLowerCase();}catch(e){}
            if((s.position==='fixed'||s.position==='absolute')&&/cookie|consent|axeptio|gdpr/.test(txt+' '+(f.id||'')+' '+(f.className||''))){f.style.setProperty('display','none','important');n++;}});
          document.querySelectorAll('[id*="axeptio" i],[class*="axeptio" i],[id*="cookie" i][style*="fixed"]').forEach(function(e){if(!e.querySelector('form')){e.style.setProperty('display','none','important');n++;}});
          document.documentElement.style.setProperty('overflow','auto','important'); document.body.style.setProperty('overflow','auto','important'); return n;})();
        """#
        _ = try? await webView.evaluateJavaScript(js)
    }

    /// Scrolls the chosen form to the top of the view, so the picture shows the form and what the site said about it.
    func scrollFormIntoView(_ token: String) async {
        _ = try? await webView.evaluateJavaScript("(function(){var f=document.querySelector('[data-ook-form=\"\(token)\"]'); if(f) f.scrollIntoView({block:'start'}); else window.scrollTo(0,0);})();")
    }

    fileprivate static func liveLiteral(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let j = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(j.dropFirst().dropLast())
    }
}

extension FormRun {
    /// Opens the page, denies cookie prompts, finds the opt-out form on the live page, fills it from the person's details, chooses the
    /// opt-out options, sends it and judges only what appeared afterwards. `person` is already the household's form view of them.
    @MainActor
    static func runLive(url: URL?, html: String?, person: Person, dryRun: Bool, maxWait: TimeInterval, capture: Bool, advertisingID: String? = nil) async -> SubmitEvidence {
        let session = WebViewSession.make()
        defer { session.close() }
        do {
            if let html { try await session.loadHTML(html) }
            else if let url, url.scheme == "https" { try await session.load(URLRequest(url: url)) }
            else { return SubmitEvidence(outcome: .failed("not a secure page")) }
        } catch { return SubmitEvidence(outcome: .failed("the page would not load")) }
        let outcome = await liveSteps(session, page: url ?? URL(string: "https://local.test/")!, person: person, dryRun: dryRun, maxWait: maxWait, advertisingID: advertisingID)
        return SubmitEvidence(outcome: outcome, screenshot: capture ? await session.screenshotJPEG(aroundForm: session.chosenForm) : nil)
    }

    @MainActor
    private static func liveSteps(_ session: WebViewSession, page: URL, person: Person, dryRun: Bool, maxWait: TimeInterval, advertisingID: String?) async -> SubmitOutcome {
        await session.settlePage(maxWait: 10)
        _ = await session.denyCookies()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        _ = await session.denyCookies()                       // prompts that load late
        await session.settlePage(maxWait: 4)
        await session.hideConsentOverlays()
        if await session.pageLooksMissing() { return .failed(FormRun.pageGone) }
        if await session.hasTermsPrompt() { return .challenged("a terms prompt that you need to accept yourself") }

        let forms = await session.discoverForms()
        let context = await session.pageContext()
        guard let form = LiveFormPicker.pick(forms, pageContext: context) else { return .failed("no opt-out form was found on the page") }
        session.chosenForm = form.token
        let plan = FormFiller.plan(for: form.asOptOutForm(page: page), signals: nil, person: person, advertisingID: advertisingID)
        switch plan.verdict {
        case .ready: break
        case .needsData(let what): return .failed("the form asks for \(what.joined(separator: ", ")), which we do not hold")
        case .needsYou(let why): return .failed(why)
        }
        let fill = await session.fillLive(plan.values)
        if fill.filled == 0 { return .failed("the form's fields could not be filled in") }
        if let miss = fill.unmatchedRequired.first { return .failed("the form's menu does not offer \(miss.isEmpty ? "your details" : miss), so this form does not apply to you") }
        let beforeFill = await session.visibleText()
        let options = await session.chooseRequestOptions(form: form.token, ownerMayConfirm: person.mayConfirmOwnIdentity())
        // Some forms send themselves the moment a choice is made. If the page already shows a confirmation, that is the result.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let earlyText = await session.visibleText()
        if earlyText != beforeFill, case .submitted(let email) = FormRun.classifyConfirmed(WebFormSubmitter.newLines(before: beforeFill, after: earlyText)), !dryRun {
            return .submitted(awaitingEmail: email)
        }
        if let missing = options.unresolved.first { return .failed("the form needs a choice we cannot make for you (\(missing))") }
        if dryRun {
            await session.scrollFormIntoView(form.token)
            #if DEBUG
            var found: [String] = []
            if await session.hasTermsPrompt() { found.append("terms") }
            if let c = await session.pendingCertification() { found.append("certify:" + c.prefix(40)) }
            if let c = await session.visibleChallenge() { found.append("check:" + c) }
            debugLastBlockers = found
            debugLastFormPage = page.absoluteString
            #endif
            return .filledNotSubmitted
        }
        if await session.pendingCertification() != nil { return .challenged("a certification box that you must tick yourself") }
        if let why = await session.visibleChallenge() { return .challenged(why) }

        let before = await session.visibleText()
        let stateBefore = await session.formState(form.token)
        guard await session.pressLiveSubmit(form: form.token) else { return .failed("no submit button found") }
        await session.settlePage(maxWait: maxWait)
        if let why = await session.visibleChallenge() { return .challenged(why) }
        await session.scrollFormIntoView(form.token)
        let after = await session.visibleText()
        #if DEBUG
        debugLastPageText = after
        #endif
        let result = WebFormSubmitter.classifyAfterSending(before: before, after: after)
        // No confirmation wording, but the form is gone or the page moved on, and nothing says it went wrong: the site took it.
        if case .failed(let why) = result, why != "nothing on the page changed after sending" || true {
            let now = await session.formState(form.token)
            let moved = !now.visible || (!now.url.isEmpty && now.url != stateBefore.url)
            let errorSeen = FormRun.classify(WebFormSubmitter.newLines(before: before, after: after).isEmpty ? "" : WebFormSubmitter.newLines(before: before, after: after)) != .failed("no success message was shown")
            if moved, !errorSeen { return .submitted(awaitingEmail: false) }
        }
        return result
    }

    #if DEBUG
    /// What the page said at the end of the last live run, for tests that check what the form received.
    nonisolated(unsafe) static var debugLastPageText = ""
    nonisolated(unsafe) static var debugLastBlockers: [String] = []
    nonisolated(unsafe) static var debugLastFormPage = ""
    #endif
}
