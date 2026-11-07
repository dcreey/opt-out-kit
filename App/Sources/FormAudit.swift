#if DEBUG
import Foundation
import OptOutKitCore

/// Simulator-only check of the live form path: opens each site's page the way a run does, fills the form from a complete made-up profile,
/// never sends it, and writes what happened (which page opened, each field and whether it was filled, what would stop a person) to
/// Documents/audit/results.json with a picture of the filled form per site. Launch with `-audit-domains a.com,b.com` or
/// `-audit-first-per-kind 3` (the first three sites of each kind of broker in the daily order).
struct AuditField: Codable {
    var label: String
    var type: String
    var required: Bool
    var filled: Bool
    var value: String
}

struct AuditSite: Codable {
    var domain: String
    var kind: String
    var opens: String
    var finalURL: String
    var method: String
    var methodReason: String
    var outcome: String
    var formFound: Bool
    var planVerdict: String
    var fields: [AuditField]
    var blockers: [String]
    var typedCodeBox: Bool
    var title: String = ""
    var formText: String = ""
    var buttons: [String] = []
}

@MainActor
enum FormAudit {
    static let pat = Person(displayName: "Pat", relationship: .me, names: [NameEntry(kind: .legal, name: "Pat Example"), NameEntry(kind: .maiden, name: "Pat Smith")],
                            addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701"), Address(street: "9 Oak Ave", city: "Peoria", state: "IL", zip: "61602", fromYear: 2015, toYear: 2018)],
                            emails: ["pat@example.com", "pat.old@example.org"],
                            phones: ["555-0100", "555-0199"], birthdate: "1980-01-01")

    /// The first `n` sites of each kind, in the order the daily batch would take them (best first).
    static func firstPerKind(_ n: Int, model: AppModel) -> [String] {
        let queue = OptOutPlan.verifyQueue(model.plan, entries: model.directory)
        let byDomain = Dictionary(model.directory.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for kind in BrokerCategory.ranked {
            var picks = queue.filter { byDomain[$0]?.about?.category == kind.rawValue }.prefix(n).map { $0 }
            if picks.count < n {   // kinds with fewer forms: top up from any site of the kind that has a page to open
                let more = model.directory.filter { $0.about?.category == kind.rawValue && !picks.contains($0.domain) && ($0.optOutForm != nil || $0.liveForm?.found == true || $0.optOutURL != nil) }
                    .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }.prefix(n - picks.count).map(\.domain)
                picks += more
            }
            out += picks
        }
        return out
    }

    /// Every site that has a page to open, in the default order of kinds, best first.
    static func all(model: AppModel) -> [String] {
        let rank = Dictionary(uniqueKeysWithValues: BrokerCategory.allCases.map { ($0.rawValue, $0.rank) })
        return model.directory.filter { $0.closed == nil && ($0.optOutForm != nil || $0.liveForm?.found == true || $0.optOutURL != nil) }
            .sorted { (rank[$0.about?.category ?? "other"] ?? 99, -($0.priority ?? 0), $0.domain) < (rank[$1.about?.category ?? "other"] ?? 99, -($1.priority ?? 0), $1.domain) }.map(\.domain)
    }

    /// Simulator only: really SENDS each site's form for the owner's profile on this device, through the same live path a run uses, and records what
    /// the site showed with a picture of the page after sending. Writes Documents/real-send/results.json (resumes) and a .jpg per site.
    static func realSend(domains: [String], model: AppModel) async {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("real-send")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("results.json")
        var rows: [[String: String]] = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([[String: String]].self, from: $0) } ?? []
        let done = Set(rows.compactMap { $0["domain"] })
        guard let me = model.people.first(where: { $0.relationship == .me }) else { return }
        let person = model.formPerson(me)
        for d in domains where !done.contains(d) {
            guard let entry = model.directory.first(where: { $0.domain == d }).map(model.resolved) else { continue }
            let page = entry.optOutForm?.page ?? entry.liveForm?.page.flatMap(URL.init(string:)) ?? entry.optOutURL
            guard let page else { continue }
            let report = await FormRun.runLive(url: page, html: nil, person: person, dryRun: false, maxWait: 25, capture: true)
            if let shot = report.screenshot { try? shot.write(to: dir.appendingPathComponent(d + ".jpg")) }
            let label: String, stored: String?
            switch report.outcome {
            case .submitted(let email): label = email ? "confirmed, awaiting an email" : "confirmed"; stored = email ? "submitted_email" : "submitted"
            case .challenged(let why): label = "check: \(why)"; stored = "challenged"
            case .rejected(let why): label = "rejected: \(why)"; stored = "rejected"
            case .failed(let why): label = "failed: \(why)"; stored = "failed"
            case .filledNotSubmitted: label = "filled, not sent"; stored = nil
            }
            if let stored { model.recordAttemptForTesting(OptOutAttempt(date: Date(), outcome: stored, detail: label), site: entry.id) }
            rows.append(["domain": d, "kind": entry.about?.category ?? "other", "page": page.absoluteString, "result": label])
            if let data = try? JSONEncoder().encode(rows) { try? data.write(to: file) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        try? "done".write(to: dir.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
    }

    /// Simulator work: the real run path (`FormRun.runLive`) in dry-run mode on each site for the owner's profile: nothing is sent. Writes Documents/dry-live/results.json.
    static func dryLive(domains: [String], model: AppModel) async {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dry-live")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let me = model.people.first(where: { $0.relationship == .me }) else { return }
        let person = model.formPerson(me)
        var rows: [[String: String]] = []
        let todo = domains.compactMap { d in model.directory.first(where: { $0.domain == d }).map(model.resolved) }
        var next = 0
        // Four sites at a time. Each writes <domain>.html (the page after every click the run made), <domain>.picked.json and a screenshot.
        await withTaskGroup(of: [String: String]?.self) { group in
            func add() {
                guard next < todo.count else { return }
                let entry = todo[next]; next += 1
                group.addTask { @MainActor in
                    guard let page = entry.optOutForm?.page ?? entry.liveForm?.page.flatMap(URL.init(string:)) ?? entry.optOutURL else { return nil }
                    let report = await FormRun.runLive(url: page, html: nil, person: person, dryRun: true, maxWait: 25, capture: true)
                    if let shot = report.screenshot { try? shot.write(to: dir.appendingPathComponent(entry.domain + ".jpg")) }
                    if let snap = FormRun.debugSnapshots.removeValue(forKey: page.absoluteString) {
                        try? snap.html.write(to: dir.appendingPathComponent(entry.domain + ".html"), atomically: true, encoding: .utf8)
                        if !snap.picked.isEmpty { try? snap.picked.write(to: dir.appendingPathComponent(entry.domain + ".picked.json"), atomically: true, encoding: .utf8) }
                    }
                    return ["domain": entry.domain, "outcome": "\(report.outcome)"]
                }
            }
            for _ in 0..<4 { add() }
            for await row in group {
                if let row { rows.append(row); if let data = try? JSONEncoder().encode(rows) { try? data.write(to: dir.appendingPathComponent("results.json")) } }
                add()
            }
        }
        try? "done".write(to: dir.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
    }

    /// Sites `from` to `to` (counting from 1) of each kind in the daily order, semi-automated queue only.
    static func range(from: Int, to: Int, model: AppModel) -> [String] {
        let queue = OptOutPlan.verifyQueue(model.plan, entries: model.directory)
        let byDomain = Dictionary(model.directory.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for kind in BrokerCategory.ranked {
            let ofKind = queue.filter { byDomain[$0]?.about?.category == kind.rawValue }
            guard ofKind.count >= from else { continue }
            out += ofKind[(from - 1)..<min(to, ofKind.count)]
        }
        return out
    }

    /// Every site in the semi-automated queue.
    static func semi(model: AppModel) -> [String] { OptOutPlan.verifyQueue(model.plan, entries: model.directory) }

    static func run(domains: [String], model: AppModel) async {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("audit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("results.json")
        // Resume: sites already audited are kept and skipped, so a long run can be stopped and started again.
        var results: [AuditSite] = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([AuditSite].self, from: $0) } ?? []
        let done = Set(results.map(\.domain))
        let todo: [DirectoryEntry] = domains.filter { !done.contains($0) }.compactMap { d in model.directory.first(where: { $0.domain == d }).map(model.resolved) }
        let width = 4
        var next = 0
        await withTaskGroup(of: AuditSite?.self) { group in
            func add() {
                guard next < todo.count else { return }
                let entry = todo[next]; next += 1
                group.addTask { @MainActor in await timed(entry, model: model, dir: dir) }
            }
            for _ in 0..<width { add() }
            for await site in group {
                if let site { results.append(site); if let data = try? JSONEncoder().encode(results) { try? data.write(to: file) } }
                add()
            }
        }
        try? "done".write(to: dir.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
    }

    /// One site, given at most 75 seconds so a page that never settles cannot hold the run.
    private static func timed(_ entry: DirectoryEntry, model: AppModel, dir: URL) async -> AuditSite? {
        await withTaskGroup(of: AuditSite?.self) { race in
            race.addTask { @MainActor in await one(entry, model: model, dir: dir) }
            race.addTask { @MainActor in
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                var site = AuditSite(domain: entry.domain, kind: entry.about?.category ?? "other", opens: "", finalURL: "", method: "", methodReason: "", outcome: "timed out after 75 seconds",
                                     formFound: false, planVerdict: "", fields: [], blockers: [], typedCodeBox: false)
                site.opens = (entry.optOutForm?.page ?? entry.liveForm?.page.flatMap(URL.init(string:)) ?? entry.optOutURL)?.absoluteString ?? ""
                return site
            }
            let first = await race.next() ?? nil
            race.cancelAll()
            return first
        }
    }

    private static func one(_ entry: DirectoryEntry, model: AppModel, dir: URL) async -> AuditSite {
        let verdict = OptOutMethods.classify(entry, confirmingIdentity: true)
        let page = entry.optOutForm?.page ?? entry.liveForm?.page.flatMap(URL.init(string:)) ?? entry.optOutURL
        var site = AuditSite(domain: entry.domain, kind: entry.about?.category ?? "other", opens: page?.absoluteString ?? "(none)", finalURL: "",
                             method: "\(verdict.method)", methodReason: verdict.reason, outcome: "", formFound: false, planVerdict: "", fields: [], blockers: [], typedCodeBox: false)
        guard let page, page.scheme == "https" else { site.outcome = "no page to open"; return site }
        let session = WebViewSession.make()
        defer { session.close() }
        do { try await session.load(URLRequest(url: page)) } catch { site.outcome = "the page would not load"; return site }
        await session.settlePage(maxWait: 10)
        _ = await session.denyCookies()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        _ = await session.denyCookies()
        await session.settlePage(maxWait: 4)
        await session.hideConsentOverlays()
        site.finalURL = session.webView.url?.absoluteString ?? ""
        if await session.pageLooksMissing() { site.outcome = "page missing (error page)"; return site }
        if await session.hasTermsPrompt() { site.blockers.append("terms prompt") }
        if let step = await session.advanceToRequestForm() { site.blockers.append("step: " + step) }
        let forms = await session.discoverFormsDeep()
        let context = await session.pageContext()
        guard let form = LiveFormPicker.pick(forms, pageContext: context) else { site.outcome = "no opt-out form found on the page (\(forms.count) forms seen)"; return site }
        site.formFound = true; session.chosenForm = form.token
        site.title = await session.pageTitle(); site.formText = form.text; site.buttons = form.buttons
        let person = model.formPerson(pat)
        let plan = FormFiller.plan(for: form.asOptOutForm(page: page), signals: nil, person: person)
        switch plan.verdict {
        case .ready: site.planVerdict = "ready"
        case .needsData(let what): site.planVerdict = "needs data: " + what.joined(separator: ", ")
        case .needsYou(let why): site.planVerdict = "needs you: " + why
        }
        let fill = await session.fillLive(plan.values)
        let options = await session.chooseRequestOptions(form: form.token, ownerMayConfirm: true)
        _ = await session.chooseCustomMenus(state: "Illinois")
        _ = await session.chooseTileButtons()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        site.typedCodeBox = await session.emptyCodeField()
        if let c = await session.pendingCertification() { site.blockers.append("certify: " + c.prefix(60)) }
        if let c = await session.visibleChallenge() { site.blockers.append("check: " + c) }
        if !options.unresolved.isEmpty { site.blockers.append("choices we cannot make: " + options.unresolved.joined(separator: ", ")) }
        if !fill.unmatchedRequired.isEmpty { site.blockers.append("menu without our value: " + fill.unmatchedRequired.joined(separator: ", ")) }
        // Read back every visible field of the chosen form.
        let tokens = form.fields.filter(\.visible).map(\.token)
        if let data = try? JSONSerialization.data(withJSONObject: tokens), let json = String(data: data, encoding: .utf8) {
            let js = #"""
            (function(tokens){return JSON.stringify(tokens.map(function(t){var el=document.querySelector('[data-ook="'+t+'"]'); if(!el) return {t:t,found:false};
              var type=(el.type||el.tagName).toLowerCase(), v='';
              if(el.tagName==='SELECT'){v=el.value?(el.options[el.selectedIndex]||{}).text||'':'';}
              else if(type==='checkbox'||type==='radio'){v=el.checked?'checked':'';} else {v=el.value||'';}
              return {t:t,found:true,v:v,req:!!(el.required||el.getAttribute('aria-required')==='true')};}));})(\#(json));
            """#
            if let out = (await session.evalLive(js)) as? String, let d = out.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                for item in arr where (item["found"] as? Bool) == true {
                    guard let f = form.fields.first(where: { $0.token == item["t"] as? String }) else { continue }
                    let v = item["v"] as? String ?? ""
                    site.fields.append(AuditField(label: f.label.isEmpty ? f.name : f.label, type: f.type, required: f.required || (item["req"] as? Bool ?? false), filled: !v.isEmpty, value: String(v.prefix(40))))
                }
            }
        }
        site.outcome = fill.filled == 0 ? "nothing could be filled" : "filled \(fill.filled) fields; dry run, nothing sent"
        await session.scrollFormIntoView(form.token)
        if let shot = await session.screenshotJPEG(aroundForm: form.token) { try? shot.write(to: dir.appendingPathComponent(entry.domain + ".jpg")) }
        return site
    }
}
#endif
