import Foundation

// MARK: What the finder sees of a page

public struct LinkSnapshot: Equatable, Sendable {
    public var href: URL
    public var text: String
    public init(href: URL, text: String) { self.href = href; self.text = text }
}

public struct FormSnapshot: Equatable, Sendable {
    public var action: URL?
    public var method: String
    public var fields: [FormField]          // visible inputs only: no hidden, submit or button inputs
    public var hasSubmit: Bool
    public init(action: URL?, method: String, fields: [FormField], hasSubmit: Bool) {
        self.action = action; self.method = method; self.fields = fields; self.hasSubmit = hasSubmit
    }
}

public struct PageSnapshot: Equatable, Sendable {
    public var url: URL
    public var status: Int?
    public var title: String
    public var text: String
    public var links: [LinkSnapshot]
    public var forms: [FormSnapshot]
    public init(url: URL, status: Int? = 200, title: String = "", text: String = "", links: [LinkSnapshot] = [], forms: [FormSnapshot] = []) {
        self.url = url; self.status = status; self.title = title; self.text = text; self.links = links; self.forms = forms
    }
}

/// Looks at a page and describes it. The app backs this with its hidden web view (so script-built pages work); tests use a fake site.
public protocol PageInspector: Sendable {
    func snapshot(_ url: URL) async -> PageSnapshot?
}

// MARK: Judging pages, links and forms (the same rules as tools/profile_brokers.py)

public enum LinkRules {
    static let optWords = try! NSRegularExpression(pattern: "opt[\\s_-]?out|remov|suppress|delete|do[\\s_-]?not[\\s_-]?sell|privacy (request|rights|choices)|control your|d[ée]sinscri|d[ée]sabonn|opposition|supprim|effac|ne pas vendre|ne vendez pas|vos droits|darse de baja|dar de baja|eliminar|borrar|no vender|derechos de privacidad|oposici[oó]n|exclusi[oó]n|abmeld|widerspr|l[öo]sch|entfern|nicht verkaufen|datenschutzrechte|ihre rechte", options: .caseInsensitive)
    static let notFound = try! NSRegularExpression(pattern: "page (can.?t|cannot|could not) be found|page not found|not found|doesn.?t exist|does not exist|error 404|404 error|\\b404\\b|oops|page introuvable|page non trouv[ée]e|n.existe pas|erreur 404|p[áa]gina no encontrada|no se encontr[óo]|no existe|seite nicht gefunden|nicht gefunden|existiert nicht|fehler 404", options: .caseInsensitive)
    static let guessPaths = ["/optout", "/opt-out", "/optout/", "/opt-out/", "/privacy", "/remove", "/removal", "/privacy-rights",
                             "/desinscription", "/confidentialite", "/privacidad", "/baja", "/datenschutz", "/abmelden", "/widerspruch"]
    static let notAFamily = ["globalprivacycontrol", "linkedin", "bing", "google", "facebook", "twitter", "x.com", "instagram", "youtube", "pinterest",
                             "reddit", "tiktok", "zendesk", "freshdesk", "helpscout", "intercom", "dataprivacyframework", "apple.com", "microsoft",
                             "amazon", "cloudflare", "wordpress", "w3.org", "gstatic", "doubleclick"]
    static let portals = ["trustarc.com", "onetrust.com", "transcend.io", "ketch.com", "datagrail.io", "privacyportal", "osano.com", "securiti.ai"]
    private static let linkWeights: [(String, Int)] = [("opt[\\s_-]?out", 10), ("do[\\s_-]?not[\\s_-]?sell", 8), ("remov", 8), ("suppress", 8),
        ("delete[\\s_-]?my|data[\\s_-]?delet", 7), ("your[\\s_-]?privacy[\\s_-]?choices|privacy[\\s_-]?rights|privacy[\\s_-]?request", 6), ("privacy", 2),
        ("d[ée]sinscri|d[ée]sabonn|darse de baja|dar de baja|abmeld", 10), ("ne pas vendre|no vender|nicht verkaufen", 8), ("supprim|effac|eliminar|borrar|l[öo]sch|entfern", 7),
        ("vos droits|droits.{0,10}(vie priv|donn)|derechos.{0,12}(privacidad|datos)|datenschutzrechte|ihre rechte|widerspr|opposition|oposici[oó]n", 6),
        ("confidentialit|privacidad|datenschutz", 2)]

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func registrable(_ host: String?) -> String {
        let parts = (host ?? "").lowercased().split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : (host ?? "").lowercased()
    }

    /// How likely a link is to lead toward an opt-out form. 0 means ignore it.
    public static func score(href: String, text: String) -> Int {
        let hay = (href + " " + text).lowercased()
        return linkWeights.reduce(0) { sum, w in hay.range(of: w.0, options: .regularExpression) != nil ? sum + w.1 : sum }
    }

    /// An error page can still carry a search box, which is not an opt-out form.
    public static func isErrorPage(_ page: PageSnapshot) -> Bool {
        if let status = page.status, status >= 400 { return true }
        return matches(notFound, page.title + " " + String(page.text.prefix(400)))
    }

    /// How likely `form` is the real opt-out form on `page` (3 or more counts), as opposed to a search box, a newsletter box,
    /// an affiliate box or a login. The page must be about opting out in its own title or opening text.
    public static func formScore(_ form: FormSnapshot, on page: PageSnapshot) -> Int {
        guard !form.fields.isEmpty else { return -9 }
        let path = page.url.path
        let context = page.title + " " + String(page.text.prefix(400))
        if path.isEmpty || path == "/" || !matches(optWords, context) { return -9 }
        let kinds = form.fields.map { "\($0.type) \($0.name) \($0.label)" }.joined(separator: " ").lowercased()
        func has(_ pattern: String) -> Bool { kinds.range(of: pattern, options: .regularExpression) != nil }
        var sc = 2
        if has("e-?mail|courriel|correo") { sc += 3 }
        if has("url|link|profile|listing|\\blien\\b|enlace") { sc += 3 }
        if has("first|last|full.?name|\\bname\\b|pr[ée]nom|nom de famille|apellido|vorname|nachname|\\bnom\\b|\\bnombre\\b") { sc += 1 }
        if form.hasSubmit { sc += 1 }
        if has("password") { sc -= 3 }
        let action = (form.action ?? page.url).absoluteString.lowercased()
        let removal = matches(optWords, action)
        if registrable(form.action?.host) != registrable(page.url.host), form.action != nil, !removal, !portals.contains(where: { action.contains($0) }) { return -9 }
        if removal { sc += 3 }
        else if has("\\bcity\\b|\\bstate\\b|\\bage\\b|zip|\\bville\\b|ciudad|\\bstadt\\b|code postal|c[óo]digo postal|\\bplz\\b") && !has("e-?mail|courriel|correo|url|link") { sc -= 4 }
        if form.fields.count <= 2, action.range(of: "search|find|lookup|people", options: .regularExpression) != nil || has("\\bq\\b|query|search"),
           !has("e-?mail|url|link") { sc -= 5 }
        return sc
    }

    public static func bestForm(on page: PageSnapshot) -> (form: FormSnapshot, score: Int)? {
        page.forms.map { ($0, formScore($0, on: page)) }.filter { $0.1 >= 3 }.max { $0.1 < $1.1 }
    }
}

// MARK: The finder

public struct FinderResult: Equatable, Sendable {
    public var form: OptOutForm?
    public var visited: [URL]
    /// Why nothing was found, in words a person can read.
    public var reason: String?
}

/// Crawls from a site's home page, following the most promising privacy and opt-out links, until it finds the real opt-out form.
/// Used to heal a link that moved or broke: nothing is sent anywhere, and no personal data is used.
public struct OptOutLinkFinder: Sendable {
    private let inspector: PageInspector
    private let maxPages: Int
    private let maxDepth: Int

    public init(inspector: PageInspector, maxPages: Int = 6, maxDepth: Int = 3) {
        self.inspector = inspector; self.maxPages = maxPages; self.maxDepth = maxDepth
    }

    private struct Candidate { var priority: Int; var depth: Int; var url: URL; var trail: [URL] }

    public func find(from home: URL) async -> FinderResult {
        var queue: [Candidate] = [Candidate(priority: 0, depth: 0, url: home, trail: [home])]
        var seen: Set<String> = [home.absoluteString]
        for path in LinkRules.guessPaths {
            if let u = URL(string: path, relativeTo: home)?.absoluteURL, seen.insert(u.absoluteString).inserted {
                queue.append(Candidate(priority: -1, depth: 1, url: u, trail: [home, u]))
            }
        }
        var visited: [URL] = []
        let ownDomain = LinkRules.registrable(home.host)
        while !queue.isEmpty, visited.count < maxPages {
            queue.sort { ($0.priority, $0.depth) > ($1.priority, $1.depth) }
            let next = queue.removeFirst()
            guard let page = await inspector.snapshot(next.url) else { continue }
            visited.append(next.url)
            if LinkRules.isErrorPage(page) { continue }
            if let (form, _) = LinkRules.bestForm(on: page) {
                let result = OptOutForm(page: page.url, method: form.method, action: form.action, fields: form.fields, hops: max(next.trail.count - 1, 0))
                return FinderResult(form: result, visited: visited, reason: nil)
            }
            guard next.depth < maxDepth else { continue }
            for link in page.links {
                let href = link.href.absoluteString.components(separatedBy: "#")[0]
                guard href.hasPrefix("http"), !["mailto:", "javascript:", "tel:"].contains(where: href.hasPrefix) else { continue }
                let score = LinkRules.score(href: href, text: link.text)
                let sameSite = LinkRules.registrable(link.href.host) == ownDomain
                if score <= 0 || (!sameSite && score < 8) || LinkRules.notAFamily.contains(where: href.contains) { continue }
                guard let url = URL(string: href) else { continue }
                // A real link to an address we only meant to guess upgrades the guess instead of being ignored as a duplicate.
                if let i = queue.firstIndex(where: { $0.url.absoluteString == url.absoluteString }) {
                    if score > queue[i].priority { queue[i] = Candidate(priority: score, depth: next.depth + 1, url: url, trail: next.trail + [url]) }
                    continue
                }
                guard seen.insert(url.absoluteString).inserted else { continue }
                queue.append(Candidate(priority: score, depth: next.depth + 1, url: url, trail: next.trail + [url]))
            }
        }
        return FinderResult(form: nil, visited: visited, reason: visited.isEmpty ? L10n.t("The site did not respond.") : L10n.f("Looked at %@ page(s) and found no opt-out form.", visited.count))
    }
}

// MARK: Links healed on this device

/// A moved link the app found for itself. It lives on the device only (there is no server), and a person can reset it.
public struct HealedLink: Codable, Equatable, Sendable {
    public var siteID: String
    public var form: OptOutForm
    public var foundAt: Date
    public init(siteID: String, form: OptOutForm, foundAt: Date = Date()) { self.siteID = siteID; self.form = form; self.foundAt = foundAt }
}

public extension Household {
    func healedLink(for siteID: String) -> HealedLink? { settings.healedLinks[siteID] }
    mutating func saveHealedLink(_ link: HealedLink) { settings.healedLinks[link.siteID] = link }
    mutating func forgetHealedLink(_ siteID: String) { settings.healedLinks[siteID] = nil }
}
