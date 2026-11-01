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
    /// The words around the form's inputs (the nearest block of text that holds them): a newsletter box says so there, whatever its button says.
    var ctx: String?

    /// The form as the filler understands it. Each field is named by its token, and its label carries the page's own name for it, so the
    /// same synonyms that read a stored form read this one.
    func asOptOutForm(page: URL) -> OptOutForm {
        OptOutForm(page: page, method: method.lowercased(), action: URL(string: action),
                   fields: fields.filter { $0.visible }.map { FormField(type: $0.type, name: $0.token, label: ($0.label + ($0.required && !$0.label.contains("*") ? " *" : "") + ($0.name.isEmpty ? "" : " | " + $0.name)).trimmingCharacters(in: .whitespaces)) }, hops: 1)
    }
}

enum LiveFormPicker {
    private static let marketing = try! NSRegularExpression(pattern: "subscribe|free trial|get started|sign.?up|log.?in|sign.?in|search|book a|demo|contact us|get in touch|newsletter|join|download|add another", options: .caseInsensitive)
    private static let optOut = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|don.?t sell|do-not-sell|privacy|delete|deletion|remove|erase|request|rights|unsubscribe|suppress|removal", options: .caseInsensitive)
    /// A form that signs someone up for something, or only sends a message to sales: never filled in, whatever the page around it says.
    private static let signup = try! NSRegularExpression(pattern: "subscribe|newsletter|sign.?up|register(?!ed)|create (an? )?account|\\bjoin\\b|waitlist|\\bdemo\\b|free trial|get started|contact sales|talk to|activation|log.?in|sign.?in|shortlist|get in touch|send message|contact us|request a (quote|call)|book a|get my [a-z ]*(guide|report)|show my report|free (guide|report)", options: .caseInsensitive)
    /// Newsletter and marketing language in the words around a form's inputs.
    private static let signupContext = try! NSRegularExpression(pattern: "newsletter|(?<!un)subscrib(e|ing|ed)|receive (updates|news|emails?)|and receive|in your inbox|to your inbox|stay (updated|in the loop)|get (the )?(latest|updates)|join our|sign.?up for|free trial|updates (and|&) insights|delivered to", options: .caseInsensitive)
    private static let strongOptOut = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|don.?t sell|privacy (request|choices|rights)|delete my|deletion request|erasure|data subject|remove (me|my)", options: .caseInsensitive)
    private static let deceasedForm = try! NSRegularExpression(pattern: "deceased|decedent|late (husband|wife|mother|father)|passed away", options: .caseInsensitive)
    private static let identity = try! NSRegularExpression(pattern: "first|last|name|email|e-mail|address|zip|postal|phone|city", options: .caseInsensitive)

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// A form whose own words say it is an opt-out or deletion request: not a search, a sign-up, a contact form or a feedback box, even on an opt-out page.
    /// Only these are sent after the first form of a page.
    static func isDedicatedOptOut(_ f: LiveForm, pageContext: String = "") -> Bool {
        guard score(f, pageContext: pageContext) >= 3 else { return false }
        let own = f.buttons.joined(separator: " ") + " " + f.text + " " + (f.ctx ?? "")
        return has(strongOptOut, own) || has(ownWords, f.buttons.joined(separator: " "))
    }
    private static let ownWords = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|unsubscribe|delete|remove|erase", options: .caseInsensitive)

    /// How likely a form is the opt-out form: opt-out wording and several identity fields count for it, marketing wording against it.
    static func score(_ f: LiveForm, pageContext: String = "") -> Int {
        let fields = f.fields.filter { $0.visible && !["hidden", "submit", "button", "image", "password"].contains($0.type) }
        guard !fields.isEmpty else { return -100 }       // a form wrapper can have no size while its fields show; only the fields count
        let buttons = f.buttons.joined(separator: " ")
        let heading = f.text
        // A sign-up, demo or contact form is refused outright unless its own button says opt-out ("Unsubscribe" is one); the page's privacy wording does not rescue it.
        if has(signup, buttons + " " + String(heading.prefix(200))) && !has(optOut, buttons) && !has(strongOptOut, heading) { return -100 }
        // The words around the inputs say "newsletter" or "delivered to your inbox": a subscription box, whatever its button says.
        let ctx = f.ctx ?? ""
        // (A subscription box is small; a form with four or more inputs is not one, whatever sits near it.)
        // (Only the form's own button or words can rescue it: a footer's "Do Not Sell" link in the same block does not make a newsletter box an opt-out.)
        if fields.count <= 3 && has(signupContext, ctx) && !has(strongOptOut, heading + " " + buttons) { return -100 }
        // A form of one input (just an email) needs something that says it is a privacy request, not only a page that mentions privacy.
        // (A privacy-policy link beside a footer box does not count: only the button, the heading or a real opt-out phrase around it does.)
        if fields.count <= 1 && !has(optOut, buttons + " " + heading) && !has(strongOptOut, ctx) { return -100 }
        var s = 0
        if has(optOut, buttons) { s += 4 }
        if has(optOut, heading) { s += 2 }
        // A form for a deceased person (a suppression list for the dead) is never the opt-out of a living one.
        if has(deceasedForm, heading + " " + buttons + " " + pageContext.prefix(300)) { s -= 8 }
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

    /// Evaluates in the frame the chosen form lives in (a page inside the page), else in the page itself.
    func evalLive(_ js: String) async -> Any? {
        if let f = activeFrame { return try? await webView.evaluateJavaScript(js, in: f, contentWorld: .page) }
        return try? await webView.evaluateJavaScript(js)
    }

    /// The forms on the page, and when the page itself shows none that looks like an opt-out form, the forms inside its frames (privacy portals are
    /// often embedded from another site). When a frame's form is the one, every later step runs in that frame.
    func discoverForms(waitForFrames: Bool = true) async -> [LiveForm] {
        activeFrame = nil
        let main = await discoverFormsIn()
        let context = await pageContext()
        if LiveFormPicker.pick(main, pageContext: context) != nil { return main }
        if waitForFrames, frames.isEmpty, ((try? await webView.evaluateJavaScript("document.querySelectorAll('iframe').length")) as? Int ?? 0) > 0 {
            try? await Task.sleep(nanoseconds: 2_500_000_000)        // a frame reports itself only once it has loaded
        }
        for frame in frames {
            activeFrame = frame.info
            let inside = await discoverFormsIn()
            if LiveFormPicker.pick(inside, pageContext: context) != nil { await scrollFrameIntoView(frame.href); return inside }
        }
        activeFrame = nil
        return main
    }

    /// Brings the frame a form is in to the middle of the screen, so the person sees it.
    func scrollFrameIntoView(_ href: String) async {
        let js = "(function(h){var fs=[].slice.call(document.querySelectorAll('iframe')); var f=fs.filter(function(x){return x.src&&(h.indexOf(x.src)===0||x.src.indexOf(h)===0);})[0]||fs[0]; if(f) f.scrollIntoView({block:'center'});})(\(Self.liveLiteral(href)));"
        _ = try? await webView.evaluateJavaScript(js)
    }

    /// A form folded inside a closed accordion (`<details>`) has no size, so it is not seen. Clicks the headings of the closed ones that hold inputs,
    /// one at a time (some sites keep only one open), and returns the forms from the first that shows an opt-out form.
    func openFoldedForms() async -> [LiveForm]? {
        let count = (try? await webView.evaluateJavaScript("document.querySelectorAll('details:not([open])').length")) as? Int ?? 0
        guard count > 0 else { return nil }
        for i in 0..<min(count, 6) {
            let js = "(function(i){var ds=[].slice.call(document.querySelectorAll('details')).filter(function(d){return d.querySelector('input,select,textarea');}); var d=ds[i]; if(!d) return false; var s=d.querySelector('summary'); if(!s) return false; if(!d.open){s.scrollIntoView({block:'center'}); s.click();} return true;})(\(i));"
            guard (try? await webView.evaluateJavaScript(js)) as? Bool == true else { break }
            try? await Task.sleep(nanoseconds: 900_000_000)
            let after = await discoverFormsIn()
            if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
        }
        return nil
    }

    /// Opens a privacy request that hides behind a link or button on the page ("Submit a privacy request", "Your Privacy Choices") when no form shows,
    /// then looks again. Only a link that opens something in the page (no address, `#` or a script) is clicked, never one that writes an email.
    func discoverFormsDeep() async -> [LiveForm] {
        let first = await discoverForms()
        if LiveFormPicker.pick(first, pageContext: await pageContext()) != nil { return first }
        if let opened = await openFoldedForms() { return opened }
        let js = #"""
        (function(){
          var re=/^\s*(submit (a |your )?(privacy|data|consumer)( rights?)? request|(make|file|start) (a |your )?(privacy|data) request|your privacy choices|privacy (request|choices|center|preferences)|data subject( access)? request|do not (sell|share)( or (sell|share))?( my (personal )?(information|info|data))?|exercise your (privacy )?rights|manage (my )?privacy( settings| choices)?)\s*[.:]?\s*$/i;
          var els=[].slice.call(document.querySelectorAll('a,button,[role=button],li,span,div,p')).filter(function(e){
            var t=(e.innerText||'').trim(); if(t.length>60||!re.test(t)) return false; if(e.children.length>2) return false;
            var r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0) return false;
            var a=e.closest('a'); var h=a?(a.getAttribute('href')||''):''; return !/^mailto:/i.test(h);});
          els.sort(function(a,b){var ha=(a.closest('a')||a).getAttribute('href')||'', hb=(b.closest('a')||b).getAttribute('href')||''; var ma=(ha===''||ha==='#'||/^javascript:/i.test(ha))?0:1, mb=(hb===''||hb==='#'||/^javascript:/i.test(hb))?0:1; return ma-mb;});
          if(!els.length) return null; var e=els[0]; e.scrollIntoView({block:'center'});
          ['mousedown','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true}));});
          return (e.innerText||'').trim();})();
        """#
        if let clicked = (try? await webView.evaluateJavaScript(js)) as? String, !clicked.isEmpty {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let after = await discoverForms()
            if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
        }
        // A choice of requests or a "who is asking" step in front of the form.
        if await advanceToRequestForm(loose: true) != nil {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let after = await discoverForms()
            if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
        }
        // The opt-out is a link to its own page: follow the clearest one that stays on the site (never a mail link or another company's page).
        let follow = #"""
        (function(){
          var host=location.hostname.replace(/^www\./,''), reg=host.split('.').slice(-2).join('.');
          var re=/^\s*(opt.?out( of (the )?sale( and sharing)?)?( request| form)?( here)?|(individual: )?opt.?out\/?(deletion)?( request)?( form)?|do not sell( or share)?( my (personal )?(information|info))?( request| form)?|submit (a )?(privacy|opt.?out|data) request|(privacy|data) (request|rights) form|delete (my|your) (data|information)|remove my information)\s*[.:]?\s*$/i;
          var as=[].slice.call(document.querySelectorAll('a[href]')).filter(function(a){
            var t=(a.innerText||'').replace(/\s+/g,' ').trim(); var h=a.getAttribute('href')||''; if(t.length>70||!re.test(t)) return false;
            if(/^(mailto:|tel:|javascript:|#)/i.test(h)) return false; var r=a.getBoundingClientRect(); if(r.width<=0||r.height<=0) return false;
            try{var u=new URL(a.href,location.href); return u.hostname.replace(/^www\./,'').split('.').slice(-2).join('.')===reg||/onetrust|trustarc|datasubject|ketch|transcend|osano|securiti|zendesk|force\.com|atlassian/.test(u.hostname);}catch(e){return false;}});
          if(!as.length) return ''; as[0].scrollIntoView({block:'center'}); location.href=as[0].href; return as[0].href;})();
        """#
        guard let went = (try? await webView.evaluateJavaScript(follow)) as? String, !went.isEmpty else { return first }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await settlePage(maxWait: 6)
        let after = await discoverForms()
        if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
        return await openFoldedForms() ?? first
    }

    /// Every visible form with its fields. Each form and field gets a `data-ook` token so later steps find the same element.
    func discoverFormsIn() async -> [LiveForm] {
        let js = #"""
        (function(){
          var vis=function(e){var r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
          var label=function(e){var t='';
            if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
            if(!t){var p=e.closest('label'); if(p) t=p.innerText;}
            // Form builders (Tally, Typeform) put the question in a heading and point the box at it: aria-labelledby="label_<id>".
            if(!t){var lb=e.getAttribute('aria-labelledby'); if(lb) t=lb.split(/\s+/).map(function(id){var n=document.getElementById(id); return n?n.innerText:'';}).join(' ');}
            if(!t) t=e.getAttribute('aria-label')||e.placeholder||e.getAttribute('title')||'';
            if(!t&&e.previousElementSibling) t=e.previousElementSibling.innerText||'';
            if(!t&&e.parentElement) t=(e.parentElement.innerText||'').slice(0,60);
            return t.replace(/\s+/g,' ').trim().slice(0,90);};
          var ctxEl=function(e){var n=e; for(var i=0;i<8&&n&&n!==document.body;i++,n=n.parentElement){var t=(n.innerText||'').replace(/\s+/g,' ').trim(); if(t.length>=25&&t.length<=700) return n;} return e.parentElement||e;};
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
                      text:(f.innerText||'').replace(/\s+/g,' ').trim().slice(0,240),ctx:(ctxEl(f).innerText||'').replace(/\s+/g,' ').trim().slice(0,600)});});
          // Single-page request portals put their inputs on the page without a <form>. Treat the loose inputs as one form.
          var loose=[].slice.call(document.querySelectorAll('input,select,textarea')).filter(function(e){
            return !e.closest('form')&&['hidden','submit','button','image','reset','search'].indexOf(e.type)<0&&vis(e);});
          if(loose.length>=1&&document.body){
            document.body.setAttribute('data-ook-form','fx'); var lf=[];
            loose.forEach(function(e,j){var type=e.tagName.toLowerCase()==='select'?'select':(e.tagName.toLowerCase()==='textarea'?'textarea':(e.type||'text'));
              var token='fx-'+j; e.setAttribute('data-ook',token); var l=label(e);
              lf.push({token:token,name:e.name||e.id||'',type:type,label:l,required:!!e.required||/\*/.test(l),visible:true});});
            // The buttons that belong to these inputs: those in the same block of the page, else every button.
            var box=ctxEl(loose[0]); var lb=[]; box.querySelectorAll('button,input[type=submit],[role=button]').forEach(function(b){if(vis(b)) lb.push(((b.innerText||b.value||'')+'').trim().slice(0,60));});
            if(!lb.length) document.querySelectorAll('button,input[type=submit],[role=button]').forEach(function(b){if(vis(b)) lb.push(((b.innerText||b.value||'')+'').trim().slice(0,60));});
            out.push({token:'fx',action:'',method:'post',visible:true,fields:lf,buttons:lb.slice(0,12),text:(box.innerText||'').replace(/\s+/g,' ').trim().slice(0,240),ctx:(box.innerText||'').replace(/\s+/g,' ').trim().slice(0,600)});}
          return JSON.stringify(out);})();
        """#
        guard let json = (await evalLive(js)) as? String, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LiveForm].self, from: data)) ?? []
    }

    /// For a site with no known form: looks for the opt-out form on the live page (opening its links, accordions and request choices) and fills it
    /// in with the person's details. Never sends. Returns how many fields were filled, 0 when no opt-out form was found.
    func scanAndFill(person: Person, advertisingID: String? = nil) async -> Int {
        await settlePage(maxWait: 6)
        _ = await denyCookies()
        _ = await advanceToRequestForm()
        let forms = await discoverFormsDeep()
        let context = await pageContext()
        guard let picked = LiveFormPicker.pick(forms, pageContext: context) else { return 0 }
        chosenForm = picked.token
        let page = webView.url ?? URL(string: "https://invalid.example/")!
        let plan = FormFiller.plan(for: picked.asOptOutForm(page: page), signals: nil, person: person, advertisingID: advertisingID)
        // Fill what we can even when the form also asks for something we do not hold: the person completes the rest.
        let fill = await fillLive(plan.values, keepExisting: true)
        if fill.filled > 0 {
            _ = await chooseRequestOptions(form: picked.token, ownerMayConfirm: person.mayConfirmOwnIdentity())
            _ = await chooseCustomMenus(state: USStates.name(for: person.currentAddress?.state ?? ""))
            _ = await chooseTileButtons()
            await scrollFormIntoView(picked.token)
        }
        return fill.filled
    }

    /// Privacy portals that open on a choice of requests ("Start Access Request", "Start Deletion Request", "Start Opt Out Request"): clicks the one a
    /// person asking to be removed wants, so the form behind it is on the page. Opt-out of sale or sharing first, then deletion; never access, transfer,
    /// correction or update. Repeats once for a second step. Returns what it clicked, or nil when the page has no such choice.
    func advanceToRequestForm(loose: Bool = false) async -> String? {
        var clicked: String?
        for _ in 0..<2 {
            let js = #"""
            (function(){
              var pref=[/delet|remov|erase/i,/opt.?out|do not sell|do not share/i], skip=/access|transfer|inaccur|correct|updat|appeal|know/i;
              var els=[].slice.call(document.querySelectorAll('button,a,[role=button],div,span,p')).filter(function(e){
                var t=(e.innerText||'').replace(/\s+/g,' ').trim(); var r=e.getBoundingClientRect();
                return (/^start .{3,50} request$/i.test(t)||/^(exert (my )?right to opt.?out|delete (my|your) (user )?(personal )?(data|information)|opt.?out of (the )?(sale|sharing)( (and|or) sharing)?( of (my|your) (personal )?(data|information))?|i am the person opting out[\s\S]{0,70}|i am (a )?consumer[\s\S]{0,50}|opt.?out form|individual: opt.?out.{0,30})$/i.test(t)||(\#(loose ? "true" : "false")&&e.tagName!=='A'&&/^(opt.?out|do not sell( or share)?( my (personal )?(information|data))?|delete( my (data|information|account))?|remove me)$/i.test(t)))&&r.width>0&&r.height>0&&e.children.length<=2;});
              for(var p=0;p<pref.length;p++){for(var i=0;i<els.length;i++){var t=(els[i].innerText||'').trim();
                if(pref[p].test(t)&&!skip.test(t)){els[i].scrollIntoView({block:'center'}); els[i].click(); return t;}}}
              return '';})();
            """#
            guard let t = (await evalLive(js)) as? String, !t.isEmpty else { break }
            clicked = t
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await settlePage(maxWait: 5)
        }
        return clicked
    }

    /// Fills the values the plan chose, finding each field by its token.
    /// Fills the form; menus that fill in after another choice (a state list that waits for the country) get a second pass.
    func fillLive(_ values: [FieldValue], keepExisting: Bool = false) async -> (filled: Int, unmatchedRequired: [String]) {
        keepExistingValues = keepExisting
        // Filling goes on for as long as it keeps getting somewhere: a choice can reveal more boxes, and each pass fills what the last one uncovered. There is
        // no fixed number of passes; it stops when a pass leaves nothing required unfilled, or fills no more than the one before (the last guard is only against a page that never settles).
        var result = await fillLiveOnce(values)
        var total = result.filled
        var pass = 1
        while !result.unmatchedRequired.isEmpty, pass < 25 {
            try? await Task.sleep(nanoseconds: 900_000_000)
            let next = await fillLiveOnce(values)
            pass += 1
            total += next.filled
            let progressed = next.unmatchedRequired.count < result.unmatchedRequired.count || next.filled > 0 && next.unmatchedRequired != result.unmatchedRequired
            result = next
            if !progressed { break }
        }
        await tryPhoneFormats()
        return (max(total, result.filled), result.unmatchedRequired)
    }

    /// When set, a text box that already holds something (a link from an email pre-fills the name and email) is left as it is.
    private static var keep: Bool = false
    private var keepExistingValues: Bool { get { Self.keep } set { Self.keep = newValue } }

    private func fillLiveOnce(_ values: [FieldValue]) async -> (filled: Int, unmatchedRequired: [String]) {
        let normal = values.filter { $0.type != FormFiller.confirmIdentityType }
        if values.contains(where: { $0.type == FormFiller.confirmIdentityType }) { _ = await tickIdentityBoxes() }
        let payload = normal.map { ["name": $0.name, "candidates": $0.candidates] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return (0, []) }
        let js = #"""
        (function(values){var filled=0, unmatched=[];
          // A box or menu the person changed themselves is theirs: later passes leave it alone. Only real input counts, never our own events.
          if(!window.__ookUserWatch){window.__ookUserWatch=true;
            ['input','change'].forEach(function(t){document.addEventListener(t,function(e){if(e.isTrusted&&e.target&&e.target.setAttribute) e.target.setAttribute('data-ook-user','1');},true);});}
          function setValue(el,v){var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
            var d=Object.getOwnPropertyDescriptor(proto,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
            el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));}
          // A phone number is typed as plain digits, with no spaces or punctuation. Only a box that shows an error gets other shapes (see tryPhoneFormats).
          // A menu of country codes ("United States (+1)") beside the box already supplies the code, so then the box takes the number alone.
          function hasCountryCode(el){var n=el.parentElement; for(var up=0;n&&up<4;up++,n=n.parentElement){
              var ss=n.querySelectorAll('select'); for(var i=0;i<ss.length;i++){var o=ss[i].options[ss[i].selectedIndex]; if(o&&/\+\d{1,3}\b/.test(o.text+' '+o.value)) return true;}
              if(n.tagName==='FORM') break;}
            return false;}
          function fmtPhone(el,raw){var d=String(raw||'').replace(/\D/g,''); if(d.length===11&&d[0]==='1') d=d.slice(1);
            var pat=el.getAttribute('pattern');
            if(d.length===10&&pat){var a=d.slice(0,3),b=d.slice(3,6),c=d.slice(6); var fs=[d,'1'+d,'+1'+d,a+'-'+b+'-'+c];
              for(var k=0;k<fs.length;k++){try{if(new RegExp('^(?:'+pat+')$').test(fs[k])) return fs[k];}catch(e){break;}}}
            return d;}
          function isPhoneBox(el){return el.tagName==='INPUT'&&(el.type==='tel'||/phone|mobile|\btel\b|telephone/i.test((el.name||'')+' '+(el.id||'')+' '+(el.getAttribute('aria-label')||'')+' '+(el.placeholder||'')));}
          values.forEach(function(v){var el=document.querySelector('[data-ook="'+v.name+'"]'); if(!el) return;
            if(el.getAttribute('data-ook-user')==='1'){filled++; return;}
            // Whatever is already in a box or menu stays, unless it is exactly what this fill put there before.
            if(el.tagName==='SELECT'){if(el.selectedIndex>0&&el.value!==''&&el.value!==el.getAttribute('data-ook-last')){filled++; return;}}
            else if((el.value||'').trim()!==''&&el.value!==el.getAttribute('data-ook-last')){filled++; return;}
            if(el.tagName==='SELECT'){var done=false;
              for(var c=0;c<v.candidates.length&&!done;c++){var want=(v.candidates[c]||'').toLowerCase();
                for(var i=0;i<el.options.length;i++){var o=el.options[i];
                  if(o.value.toLowerCase()===want||o.text.trim().toLowerCase()===want){el.value=o.value;done=true;break;}}}
              // Options such as "IL - Illinois" or "Illinois (IL)": a state name inside the text, or the two-letter code as a whole word.
              for(var c2=0;c2<v.candidates.length&&!done;c2++){var w2=(v.candidates[c2]||'').toLowerCase(); if(!w2) continue;
                for(var i2=0;i2<el.options.length;i2++){var o2=el.options[i2], tx=o2.text.trim().toLowerCase(); if(!o2.value&&!tx) continue;
                  var hit=w2.length>2?tx.indexOf(w2)>=0:new RegExp('(^|[^a-z])'+w2+'([^a-z]|$)').test(tx);
                  if(hit&&!/other|not listed|outside/.test(tx)){el.value=o2.value;done=true;break;}}}
              if(!done&&/state|province|region/i.test((el.name||'')+' '+(el.id||'')+' '+(el.getAttribute('aria-label')||''))){
                // No match for the person's state: take "Other US state" / "Other" / "Not listed" when the menu has one.
                for(var k=0;k<el.options.length&&!done;k++){var tx=el.options[k].text.trim();
                  if(/^(other( u\.?s\.?( state)?s?)?|other state|not listed|outside (the )?u\.?s)/i.test(tx)){el.value=el.options[k].value;done=true;}}}
              if(done){el.dispatchEvent(new Event('change',{bubbles:true}));el.setAttribute('data-ook-last',el.value);filled++;}
              else if(el.required||/\*|required/i.test((el.getAttribute('aria-label')||'')+(el.closest('label')?el.closest('label').innerText:'')+(el.id&&document.querySelector('label[for="'+el.id+'"]')?document.querySelector('label[for="'+el.id+'"]').innerText:''))) unmatched.push((v.candidates[0]||'')+'');
            } else if(\#(keepExistingValues ? "true" : "false")&&(el.value||'').trim()!==''){filled++;}
            else if(v.candidates.length&&v.candidates[0]!==null){var ph=isPhoneBox(el); setValue(el,ph?fmtPhone(el,v.candidates[0]):v.candidates[0]); el.setAttribute('data-ook-last',el.value); if(ph) el.setAttribute('data-ook-phone',String(v.candidates[0]).replace(/\D/g,'')); filled++;}});
          return JSON.stringify({filled:filled,unmatched:unmatched});})(\#(json));
        """#
        guard let out = (await evalLive(js)) as? String, let d = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (0, []) }
        return (obj["filled"] as? Int ?? 0, obj["unmatched"] as? [String] ?? [])
    }

    /// Looks at the phone boxes this fill typed into; one that shows an error (a failed pattern, an invalid flag, a visible error message) is tried
    /// again in other shapes, one at a time, until the error clears. A box the person changed is never touched, and when no shape works the plain digits go back.
    func tryPhoneFormats() async {
        guard await evalLive("document.querySelector('[data-ook-phone]')!==null") as? Bool == true else { return }
        try? await Task.sleep(for: .milliseconds(250))
        for step in 1...10 {
            guard await phoneFormatStep(step) else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// One round of `tryPhoneFormats`: false when no box is in error or no other shape is left to try.
    private func phoneFormatStep(_ step: Int) async -> Bool {
        let js = #"""
        (function(step){var bad=0, more=false;
          function hasCC(el){var n=el.parentElement; for(var up=0;n&&up<4;up++,n=n.parentElement){var ss=n.querySelectorAll('select');
            for(var i=0;i<ss.length;i++){var o=ss[i].options[ss[i].selectedIndex]; if(o&&/\+\d{1,3}\b/.test(o.text+' '+o.value)) return true;} if(n.tagName==='FORM') break;} return false;}
          function visible(e){var r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&getComputedStyle(e).visibility!=='hidden'&&(e.innerText||'').trim()!=='';}
          function invalid(el){
            if(el.willValidate&&!el.checkValidity()) return true;
            if(el.getAttribute('aria-invalid')==='true') return true;
            var cls=(el.className||'')+' '+(el.parentElement?el.parentElement.className||'':''); if(/(^|[\s_-])(is-invalid|invalid|has-error|ng-invalid|error)($|[\s_-])/i.test(cls)) return true;
            var n=el.parentElement; for(var up=0;n&&up<2;up++,n=n.parentElement){var errs=n.querySelectorAll('[role=alert],.error,.invalid-feedback,.field-error,.help-block,[class*=error]');
              for(var i=0;i<errs.length;i++) if(!errs[i].contains(el)&&visible(errs[i])&&/phone|number|digit|valid|format|invalid|required/i.test(errs[i].innerText)) return true;}
            return false;}
          function set(el,v){var d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
            ['input','change','blur','focusout'].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}));}); el.setAttribute('data-ook-last',el.value);}
          [].slice.call(document.querySelectorAll('[data-ook-phone]')).forEach(function(el){
            if(el.getAttribute('data-ook-user')==='1'||el.value!==el.getAttribute('data-ook-last')) return;
            var d=el.getAttribute('data-ook-phone'); if(d.length===11&&d[0]==='1') d=d.slice(1); if(d.length!==10) return;
            ['blur','focusout'].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}));});
            if(!invalid(el)) return;
            var a=d.slice(0,3),b=d.slice(3,6),c=d.slice(6);
            var forms=hasCC(el)?[d,a+'-'+b+'-'+c,'('+a+') '+b+'-'+c,a+'.'+b+'.'+c,a+' '+b+' '+c]:[d,'1'+d,'+1'+d,a+'-'+b+'-'+c,'('+a+') '+b+'-'+c,a+'.'+b+'.'+c,a+' '+b+' '+c,'+1 '+a+' '+b+' '+c,'1-'+a+'-'+b+'-'+c];
            bad++;
            if(step<forms.length){set(el,forms[step]); more=true;} else { set(el,d); }
          });
          return JSON.stringify({bad:bad,more:more});})(\#(step));
        """#
        guard let out = await evalLive(js) as? String, let d = out.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (obj["bad"] as? Int ?? 0) > 0 && obj["more"] as? Bool == true
    }

    /// Brings the form being filled to the top of the screen, so the person sees what was filled and does not have to hunt for it.
    func scrollFormIntoView(token: String) async {
        let js = "(function(t){var f=document.querySelector('[data-ook-form=\"'+t+'\"]'); if(f){f.scrollIntoView({block:'start',behavior:'instant'}); window.scrollBy(0,-12); return true;} return false;})(\(Self.liveLiteral(token)));"
        _ = await evalLive(js)
    }

    /// When the page now shows an opt-out button or link below the visible part ("Opt out" next to a listing that a search found), scrolls to it.
    /// Does nothing when one is already on screen, so it never moves a page the person is using. True when it scrolled.
    func scrollToOptOutControl() async -> Bool {
        let js = #"""
        (function(){var re=/opt.?(me.?)?out|remove (me|my|this)|do not sell|delete my/i;
          var els=[].slice.call(document.querySelectorAll('a,button,input[type=submit],input[type=button],[role=button]')).filter(function(e){var t=(e.innerText||e.value||'').trim();
            if(!re.test(t)||t.length>60) return false; var r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&!(e.closest&&e.closest('nav,header,footer'));});
          if(!els.length) return false;
          if(els.some(function(e){var r=e.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight;})) return false;
          els[0].scrollIntoView({block:'center',behavior:'smooth'}); return true;})();
        """#
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    /// A page that offers its one opt-out form as tabs ("Phone" and "Name"): opens the name tab, which is the one that takes a person's listing off.
    /// Returns true when it pressed one.
    func chooseNameTab() async -> Bool {
        let js = #"""
        (function(){var vis=function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;};
          var items=[].slice.call(document.querySelectorAll('[role=tab],.nav-link,.tab,li,button,a,label,div,span')).filter(function(e){return vis(e)&&e.children.length<=1&&(e.innerText||'').trim().length<24;});
          var by=function(re){return items.filter(function(e){return re.test((e.innerText||'').trim());});};
          var names=by(/^(by )?(full )?(name|name lookup|people|person)$/i), phones=by(/^(by )?(phone|phone number|phone lookup|number)$/i);
          if(!names.length||!phones.length) return false;
          var n=names.filter(function(e){return /^(A|BUTTON)$/.test(e.tagName)||e.getAttribute('role')==='tab';})[0]||names.filter(function(e){return e.children.length===0;})[0]||names[0]; if(n.getAttribute('aria-selected')==='true'||/\bactive\b|\bselected\b/.test(n.className||'')) return false;
          n.click(); return true;})();
        """#
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    /// Chooses, inside one form, the options an opt-out needs: "this request is for myself", the opt-out and deletion choices, and a
    /// request-type menu. It never ticks access, correction or marketing choices, and never picks "authorized agent" or "deceased".
    /// Returns what it chose, and the names of required choices it could not make.
    /// Pages that ask "I am a(n)" or "Select request type" with a row of buttons instead of radio boxes: picks the plain consumer or "other" answer, and the
    /// opt-out or deletion request (never access, update, correction or transfer). Returns how many it pressed.
    /// Page script shared by the choosers: what the person tapped or changed is theirs, and what the app chose once it does not choose again.
    /// A refill (after a check is solved, before sending) must never undo a tile, box or menu the person set, nor tap a tile a second time (a tile that
    /// toggles would switch our own choice off). Only real taps count (`isTrusted`), never our own clicks.
    static let ownershipJS = #"""
        if(!window.__ookUserWatch){window.__ookUserWatch=true;
          ['input','change'].forEach(function(t){document.addEventListener(t,function(e){if(e.isTrusted&&e.target&&e.target.setAttribute) e.target.setAttribute('data-ook-user','1');},true);});}
        if(!window.__ookClickWatch){window.__ookClickWatch=true; window.__ookTouched=[];
          document.addEventListener('click',function(e){if(e.isTrusted&&e.target&&e.target.nodeType===1){window.__ookTouched.push(e.target); if(window.__ookTouched.length>80) window.__ookTouched.shift();}},true);}
        var touched=function(el){var t=window.__ookTouched||[];
          for(var i=0;i<t.length;i++){var x=t[i]; var lab=x.closest?x.closest('label'):null;
            if(x===el||el.contains(x)||(x.tagName==='LABEL'&&x.htmlFor&&x.htmlFor===el.id)||(lab&&lab.contains(el))) return true;}
          return el.getAttribute('data-ook-user')==='1';};
        var autoDone=function(el){return el.getAttribute('data-ook-auto')==='1';};
        var markAuto=function(el){el.setAttribute('data-ook-auto','1');};
        """#

    /// Every email address the page shows or links to (mailto links and addresses in the text), for the one a privacy request should go to.
    func pageEmails() async -> [String] {
        let js = #"""
        (function(){var out=[]; document.querySelectorAll('a[href^="mailto:" i]').forEach(function(a){out.push((a.getAttribute('href')||'').replace(/^mailto:/i,'').split('?')[0]);});
          var m=(document.body?document.body.innerText:'').match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g)||[]; return JSON.stringify(out.concat(m));})();
        """#.replacingOccurrences(of: "\\.", with: "\\.")
        guard let json = (await evalLive(js)) as? String, let data = json.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }

    func chooseTileButtons() async -> Int {
        let js = #"""
        (function(){
          \#(Self.ownershipJS)
          var vis=function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;};
          var n=0; window.__ookTiles=window.__ookTiles||{};
          document.querySelectorAll('label,legend,h2,h3,h4,p,span,div').forEach(function(h){
            var t=(h.innerText||'').replace(/\s+/g,' ').replace(/\s*required\s*$/i,'').trim(); if(t.length>60||h.children.length>3) return;
            var who=/^\*?\s*I am an?\b/i.test(t), what=/^\*?\s*(select )?(the )?(request type|right to exercise|type of request)/i.test(t);
            if(!who&&!what) return;
            var box=h.parentElement, btns=[]; for(var up=0;up<4&&box;up++,box=box.parentElement){btns=[].slice.call(box.querySelectorAll('button,[role=button],[role=radio],[role=option],label,[class*=option],[class*=choice],[class*=tile]')).filter(function(b){return vis(b)&&b!==h&&(b.innerText||'').trim().length>1&&(b.innerText||'').trim().length<80&&b.children.length<=2;}); if(btns.length>=2) break;}
            if(btns.length<2) return;
            // A group is handled once per page: after that, and whenever the person has tapped any of its tiles, it is theirs.
            if(window.__ookTiles[t]) return; window.__ookTiles[t]=1;
            if(btns.some(touched)||btns.some(function(b){return b.getAttribute('aria-pressed')==='true'||/selected|active|checked/.test(b.className||'');})) return;
            var bad=/employee|customer|client|vendor|partner|contractor|applicant|agent|representative|prospect|access|know|correct|updat|edit|transfer|portab|appeal/i;
            var prefs=who?[/^other$/i,/consumer|individual|myself|general public|member of the public/i]:[/delet|remov|erase/i,/opt.?out|do not sell|do not share/i];
            for(var p=0;p<prefs.length;p++){for(var i=0;i<btns.length;i++){var bt=(btns[i].innerText||'').trim(); if(prefs[p].test(bt)&&!bad.test(bt)){btns[i].scrollIntoView({block:'center'}); markAuto(btns[i]); btns[i].click(); n++; return;}}}
          });
          return n;})();
        """#
        return (await evalLive(js)) as? Int ?? 0
    }

    func chooseRequestOptions(form token: String, ownerMayConfirm: Bool = false) async -> (chosen: Int, unresolved: [String]) {
        let js = #"""
        (function(token){
          var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return JSON.stringify({chosen:0,unresolved:[]});
          \#(Self.ownershipJS)
          var label=function(e){var t='';
            if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
            if(!t){var p=e.closest('label'); if(p) t=p.innerText;}
            if(!t){var lb=e.getAttribute('aria-labelledby'); if(lb) t=lb.split(/\s+/).map(function(id){var n=document.getElementById(id); return n?n.innerText:'';}).join(' ');}
            if(!t) t=e.getAttribute('aria-label')||e.getAttribute('value')||'';
            if(!t&&e.nextSibling&&e.nextSibling.textContent) t=e.nextSibling.textContent;
            return t.replace(/\s+/g,' ').trim();};
          var title=function(e){var t=''; if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
            if(!t){var p=e.closest('label'); if(p) t=p.innerText;} return (t||'').split(/\n/)[0].trim().slice(0,80);};
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
          var agentQ=/authori[sz]ed agent|on behalf|acting as (an )?agency|submitting (this )?request (on|for)|are you (an? )?(agent|agency)/i;
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
            if(rm&&!rm.checked){markAuto(rm); rm.click(); if(!rm.checked){rm.checked=true; rm.dispatchEvent(new Event('change',{bubbles:true}));} chosen++; return;}
            if(rs.some(function(r){return r.checked;})) return;
            var pick=null;
            // "Are you an authorized agent / acting on behalf of someone?": the person is asking for themselves, so the answer is No.
            var ctx=((rs[0].closest('fieldset')||rs[0].closest('div')||{innerText:''}).innerText||'').slice(0,200)+' '+(rs[0].name||'');
            if(agentQ.test(ctx)){for(var q=0;q<rs.length&&!pick;q++){var lt=label(rs[q]); if(/^\s*(no|myself|me|my own|not an agent|individual)\b/i.test(lt)) pick=rs[q];}}
            for(var i=0;i<rs.length&&!pick;i++){var t=label(rs[i]); if(self.test(t)&&!notSelf.test(t)) pick=rs[i];}
            // "Remove my information" (a person-search site taking a listing off) beats a plain "do not sell" choice beside it: it is the stronger opt-out.
            for(var i=0;i<rs.length&&!pick;i++){var ti=title(rs[i]); if(/\b(remov|delet|eras)\w*\b.{0,12}\b(my|me)\b.{0,12}\b(info|information|record|records|listing|profile|data)\b/i.test(ti)) pick=rs[i];}
            for(var i=0;i<rs.length&&!pick;i++){var t=label(rs[i]); if(yesOrOptOut(t)||isDecl(t)) pick=rs[i];}
            if(pick){markAuto(pick); pick.click(); if(!pick.checked){pick.checked=true; pick.dispatchEvent(new Event('change',{bubbles:true}));} chosen++;}
            else if(rs.some(function(r){return r.required;})) unresolved.push(label(rs[0])||k);});
          f.querySelectorAll('input[type=checkbox]').forEach(function(c){var t=label(c);
            if(c.checked||!t||touched(c)||autoDone(c)) return;
            // "I am submitting this request for myself" (next to "...on behalf of someone else"): the person is asking for themselves.
            if(/\b(for )?myself\b|\bfor me\b|\bmy own\b/i.test(t)&&!notSelf.test(t)){markAuto(c); c.click(); if(!c.checked){c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));} chosen++; return;}
            if(yesOrOptOut(t)||isDecl(t)){markAuto(c); c.click(); if(!c.checked){c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));} chosen++;}});
          f.querySelectorAll('select').forEach(function(s){
            var l=((s.name||'')+' '+(s.getAttribute('aria-label')||'')).toLowerCase();
            var near=(s.closest('div')?s.closest('div').innerText:'').toLowerCase().slice(0,120);
            // A menu of states or countries is filled by value; a request-type menu that merely sits near the word "state" is not one.
            if(/state|country|province|region/.test(l)||s.options.length>=40) return;
            if((s.selectedIndex>0 && s.value)||touched(s)||autoDone(s)) return;
            var best=-1,bestScore=0;
            var isAgentQ=agentQ.test(l+' '+near);
            for(var i=0;i<s.options.length;i++){var t=s.options[i].text; var sc=0;
              if(isAgentQ&&/^\s*(no|myself|me|my own|not an agent|individual)\b/i.test(t)) sc=5;
              if(/opt.?out|do not sell|do not share|unsubscribe/i.test(t)) sc=2;
              if(/delet|remov|eras/i.test(t)) sc=Math.max(sc,3);          // deleting the data beats opting out of its sale
              if(/\b(consumer|individual|personal|myself|resident|person|the (person|individual|subject)|data subject|yourself|owner|me)\b/i.test(t)&&!/business|agent|deceased|on behalf|representative/i.test(t)) sc=Math.max(sc,1);
              // "Relationship with us" menus: a person who is only asking to be removed is a consumer, not a customer, employee or partner.
              if(/relationship|how do we know|are you a|i am/i.test(l+' '+near)&&/\b(consumer|individual|none of the above|not a (customer|client|user)|no relationship|general public|just a consumer|other)\b/i.test(t)&&!/business|agent|employee|partner|client of|vendor/i.test(t)) sc=Math.max(sc,1);
              if(/access|know|correct|update|portab/i.test(t)) sc=0;
              if(sc>bestScore){bestScore=sc;best=i;}}
            var placeholder=s.selectedIndex<=0;
            if(best>=0&&placeholder){markAuto(s); s.selectedIndex=best; s.dispatchEvent(new Event('change',{bubbles:true})); s.dispatchEvent(new Event('input',{bubbles:true})); chosen++;}
            else if(s.required&&placeholder) unresolved.push((near.split('\n')[0]||l||'a menu').slice(0,60));});
          return JSON.stringify({chosen:chosen,unresolved:unresolved});})(\#(Self.liveLiteral(token)));
        """#
        guard let json = (await evalLive(js)) as? String, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, []) }
        return (obj["chosen"] as? Int ?? 0, obj["unresolved"] as? [String] ?? [])
    }

    /// The label of the first required menu, text box or choice in the form that is still empty, or nil when all are filled. A person is asked to
    /// fill it in: a state list without their state, a request type the app could not pick. Boxes that only certify something are left to their own rule.
    func emptyRequiredChoice(form token: String) async -> String? {
        let js = #"""
        (function(token){var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return '';
          var label=function(e){var t=''; if(e.id){var l=document.querySelector('label[for="'+e.id+'"]'); if(l) t=l.innerText;}
            if(!t){var p=e.closest('label'); if(p) t=p.innerText;} if(!t) t=e.getAttribute('aria-label')||e.placeholder||e.name||'';
            return t.replace(/\s+/g,' ').replace(/\*|\(required\)/gi,'').trim().slice(0,60);};
          var els=[].slice.call(f.querySelectorAll('select,input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button]),textarea'));
          for(var i=0;i<els.length;i++){var e=els[i], r=e.getBoundingClientRect(); if(r.width<=0||r.height<=0) continue;
            var req=e.required||e.getAttribute('aria-required')==='true'||/\*/.test(label(e)+(e.closest('label')?e.closest('label').innerText:''));
            if(!req) continue;
            var empty=e.tagName==='SELECT'?(!e.value||e.selectedIndex<=0&&!e.options[e.selectedIndex].value):!(e.value||'').trim();
            if(empty && !/captcha|code/i.test(label(e))) return label(e)||'a required choice';}
          return '';})(\#(Self.liveLiteral(token)));
        """#
        let out = (await evalLive(js)) as? String
        return (out?.isEmpty ?? true) ? nil : out
    }

    /// The label of a confirmation button on the page ("Confirm request", "Verify my email"), scrolled into view, or nil. It is only found, never pressed:
    /// confirming is the person's own tap.
    func confirmButtonLabel() async -> String? {
        let js = #"""
        (function(){var bs=[].slice.call(document.querySelectorAll('button,a,[role=button],input[type=submit]')).filter(function(b){
          var t=((b.innerText||b.value||'')+'').replace(/\s+/g,' ').trim(), r=b.getBoundingClientRect();
          return r.width>0&&r.height>0&&/^(confirm( my)?( request| email| opt.?out)?|verify( my)?( request| email)?|complete( my)?( request)?|yes,? (confirm|opt out|delete))$/i.test(t);});
          if(!bs.length) return ''; bs[0].scrollIntoView({block:'center'}); return ((bs[0].innerText||bs[0].value||'')+'').trim();})();
        """#
        let out = (await evalLive(js)) as? String
        return (out?.isEmpty ?? true) ? nil : out
    }

    /// Custom drop-down menus that are not <select> elements (Material UI and similar): opens each empty one that asks about the person's relationship
    /// to the company or their state, and picks a consumer-style answer ("Consumer", "None", "Other", the person's state). Never picks employee,
    /// customer, vendor or business answers. Returns how many it set.
    /// `state` is the person's own state or region name: a menu that lists places picks that one, and never another.
    func chooseCustomMenus(state: String? = nil) async -> Int {
        var set = 0
        // Every empty menu on the form is set, however many there are: the loop ends when none is left (the bound only guards against a page that keeps adding menus).
        for _ in 0..<60 {
            let open = #"""
            (function(){
              var els=[].slice.call(document.querySelectorAll('[role=combobox],[aria-haspopup=listbox],.MuiSelect-select')).filter(function(e){
                var r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&!e.getAttribute('data-ook-menu')&&((e.innerText||e.value||'').replace(/[\u200b\s]/g,'')==='');});
              if(!els.length) return '';
              var e=els[0]; e.setAttribute('data-ook-menu','1'); e.scrollIntoView({block:'center'});
              ['mousedown','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true}));});
              return ((e.closest('div[class*=FormControl],div')||e).innerText||'').replace(/\s+/g,' ').slice(0,120)||'menu';})();
            """#
            guard let label = (await evalLive(open)) as? String, !label.isEmpty else { break }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let pick = #"""
            (function(){
              var opts=[].slice.call(document.querySelectorAll('[role=option],li[role=menuitem],[role=listbox] li')).filter(function(o){var r=o.getBoundingClientRect(); return r.width>0&&r.height>0;});
              var bad=/employee|customer|client|vendor|partner|supplier|business|contractor|applicant|agent|representative|former|prospect/i;
              var good=[\#(state.flatMap { $0.isEmpty ? nil : "/^\\s*" + NSRegularExpression.escapedPattern(for: $0) + "\\b/i," } ?? "")/consumer|individual|myself|general public|member of the public/i,/^\s*(none|n\/a|not applicable|no relationship)/i,/\bother\b/i];
              for(var g=0;g<good.length;g++){for(var i=0;i<opts.length;i++){var t=(opts[i].innerText||'').trim(); if(good[g].test(t)&&!bad.test(t)){opts[i].click(); return t;}}}
              if(opts.length&&opts.length<40){var last=opts[opts.length-1]; if(!bad.test(last.innerText||'')){last.click(); return (last.innerText||'').trim();}}
              document.body.click(); return '';})();
            """#
            if let t = (await evalLive(pick)) as? String, !t.isEmpty { set += 1 }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return set
    }

    /// After a form's first button ("Review Request"), the page often shows a summary with its own final button ("Submit Request", "Confirm"): presses
    /// that one. Only when the page says it is a review or confirmation step, so a form is never sent twice. Returns whether it pressed something.
    func pressConfirmStep() async -> Bool {
        let js = #"""
        (function(){
          var text=(document.body?document.body.innerText:'').toLowerCase();
          if(!/review (your )?(request|information|details)|please (review|confirm)|confirm your (request|submission)|check your (details|information)/.test(text)) return false;
          var bs=[].slice.call(document.querySelectorAll('button,input[type=submit],[role=button]')).filter(function(b){
            var t=((b.innerText||b.value||'')+'').replace(/\s+/g,' ').trim(), r=b.getBoundingClientRect();
            return r.width>0&&r.height>0&&/^(submit( request)?|confirm( request)?|send( request)?|yes,? submit)$/i.test(t);});
          if(!bs.length) return false; bs[bs.length-1].scrollIntoView({block:'center'}); bs[bs.length-1].click(); return true;})();
        """#
        return ((await evalLive(js)) as? Bool) ?? false
    }

    /// Presses the chosen form's own send button, whatever it says ("Opt me out", "Submit request"); never one that says agree, accept or cancel.
    func pressLiveSubmit(form token: String) async -> Bool {
        let js = #"""
        (function(token){var f=document.querySelector('[data-ook-form="'+token+'"]'); if(!f) return false;
          var bad=/agree|accept|cancel|clear|reset|back|add another|^\+|subscribe/i;
          // A sign-up, demo or contact button is never pressed, whatever the form around it says (an "unsubscribe" or opt-out button is fine).
          var signup=/subscribe|newsletter|sign.?up|register(?!ed)|create (an? )?account|\bjoin\b|waitlist|\bdemo\b|free trial|get started|contact sales|talk to|activation|log.?in|sign.?in|get in touch|send message|contact us|book a/i, optout=/opt.?out|unsubscribe|do not sell|remove|delete|privacy/i;
          var refuse=function(b){var t=((b.innerText||b.value||'')+'').trim(); return signup.test(t)&&!optout.test(t);};
          var bs=[].slice.call(f.querySelectorAll('button,input[type=submit],input[type=button],[role=button]')).filter(function(b){
            var t=((b.innerText||b.value||'')+'').trim(); var r=b.getBoundingClientRect(); return r.width>0&&r.height>0&&!bad.test(t);});
          var pick=null;
          for(var i=0;i<bs.length&&!pick;i++){var ty=(bs[i].getAttribute('type')||'').toLowerCase(); if(ty==='submit') pick=bs[i];}
          for(var i=0;i<bs.length&&!pick;i++){if(/submit|send|opt|continue|request|go|confirm|remove|delete/i.test((bs[i].innerText||bs[i].value||''))) pick=bs[i];}
          if(!pick&&bs.length) pick=bs[bs.length-1];
          if(pick&&refuse(pick)) return false;
          if(pick){pick.scrollIntoView({block:'center'}); pick.click(); return true;}
          if([].slice.call(f.querySelectorAll('button,input[type=submit],[role=button]')).some(refuse)) return false;
          if(f.requestSubmit){f.requestSubmit(); return true;} f.submit(); return true;})(\#(Self.liveLiteral(token)));
        """#
        return ((await evalLive(js)) as? Bool) ?? false
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
        return ((await evalLive(js)) as? Bool) ?? false
    }

    /// Whether the chosen form is still on the page and visible, and the page's address.
    func formState(_ token: String) async -> (visible: Bool, url: String) {
        let js = "(function(){var f=document.querySelector('[data-ook-form=\"\(token)\"]'); var v=false; if(f){var r=f.getBoundingClientRect(),s=getComputedStyle(f); v=r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';} return JSON.stringify({v:v,u:location.href});})();"
        guard let out = (await evalLive(js)) as? String, let d = out.data(using: .utf8),
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
        _ = await evalLive(js)
    }

    /// Scrolls the chosen form to the top of the view, so the picture shows the form and what the site said about it.
    func scrollFormIntoView(_ token: String) async {
        _ = await evalLive("(function(){var f=document.querySelector('[data-ook-form=\"\(token)\"]'); if(f) f.scrollIntoView({block:'start'}); else window.scrollTo(0,0);})();")
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
        #if DEBUG
        if dryRun, capture {
            // For offline analysis: the page as it stands after every click the run made, and a summary of the form it chose.
            var snapshot = (html: ((try? await session.webView.evaluateJavaScript("document.documentElement.outerHTML")) as? String) ?? "", picked: "")
            if let token = session.chosenForm {
                let js = "(function(t){var f=document.querySelector('[data-ook-form=\"'+t+'\"]'); if(!f) return ''; var q=function(e){return (e.innerText||e.value||'').replace(/\\s+/g,' ').trim().slice(0,60);}; var n=f; for(var i=0;i<8&&n&&n!==document.body;i++,n=n.parentElement){var x=(n.innerText||'').replace(/\\s+/g,' ').trim(); if(x.length>=25&&x.length<=700) break;} return JSON.stringify({fields:[].slice.call(f.querySelectorAll('input,select,textarea')).filter(function(e){return !/hidden|submit|button|image|reset|checkbox|radio/.test(e.type)}).map(function(e){return (e.type||e.tagName)+':'+(e.name||e.id||'')}),buttons:[].slice.call(f.querySelectorAll('button,input[type=submit],[role=button]')).map(q).filter(Boolean),ctx:((n&&n.innerText)||'').replace(/\\s+/g,' ').trim().slice(0,300),url:location.href});})(\(WebViewSession.liveLiteral(token)));"
                snapshot.picked = ((try? await session.webView.evaluateJavaScript(js)) as? String) ?? ""
            }
            snapshot.picked += "\n" + (url.flatMap { debugForms[$0.absoluteString] } ?? "")
            if let url { debugSnapshots[url.absoluteString] = snapshot }
        }
        #endif
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

        _ = await session.advanceToRequestForm()
        let forms = await session.discoverFormsDeep()
        let context = await session.pageContext()
        #if DEBUG
        debugForms[page.absoluteString] = forms.map { "\($0.token) score=\(LiveFormPicker.score($0, pageContext: context)) text=\($0.text) | buttons=\($0.buttons) fields=\($0.fields.map { "\($0.type):\($0.name):\($0.visible)" }) | ctx=\($0.ctx ?? "")" }.joined(separator: "\n")
        #endif
        guard let picked = LiveFormPicker.pick(forms, pageContext: context) else { return .failed("no opt-out form was found on the page") }
        var form = picked
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
        var options = await session.chooseRequestOptions(form: form.token, ownerMayConfirm: person.mayConfirmOwnIdentity())
        _ = await session.chooseCustomMenus(state: USStates.name(for: person.currentAddress?.state ?? ""))
        _ = await session.chooseTileButtons()
        // Choosing "remove my information" can open a second form with more boxes (state, birth date): read the page again and fill those too.
        if options.chosen > 0 {
            try? await Task.sleep(nanoseconds: 800_000_000)
            let known = WebAssistedDriver.signature(form)
            let again = await session.discoverForms(waitForFrames: false)
            if let fresh = again.filter({ LiveFormPicker.score($0, pageContext: context) >= 3 && WebAssistedDriver.signature($0) != known })
                .max(by: { LiveFormPicker.score($0, pageContext: context) < LiveFormPicker.score($1, pageContext: context) }) {
                form = fresh
                session.chosenForm = fresh.token
                let second = FormFiller.plan(for: fresh.asOptOutForm(page: page), signals: nil, person: person, advertisingID: advertisingID)
                switch second.verdict {
                case .ready: break
                case .needsData(let what): return .failed("the form asks for \(what.joined(separator: ", ")), which we do not hold")
                case .needsYou(let why): return .failed(why)
                }
                let more = await session.fillLive(second.values, keepExisting: true)
                if let miss = more.unmatchedRequired.first { return .failed("the form's menu does not offer \(miss.isEmpty ? "your details" : miss), so this form does not apply to you") }
                options = await session.chooseRequestOptions(form: fresh.token, ownerMayConfirm: person.mayConfirmOwnIdentity())
                _ = await session.chooseCustomMenus(state: USStates.name(for: person.currentAddress?.state ?? ""))
            }
        }
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
        if await session.pressConfirmStep() { await session.settlePage(maxWait: maxWait) }          // a review step with its own final button
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
    nonisolated(unsafe) static var debugForms: [String: String] = [:]
    nonisolated(unsafe) static var debugSnapshots: [String: (html: String, picked: String)] = [:]
    nonisolated(unsafe) static var debugLastFormPage = ""
    #endif
}
