#if DEBUG
import SwiftUI
import WebKit
import OptOutKitCore

/// Temporary admin screen, debug builds only (the simulator): goes through the sites that have no readable opt-out form, one at a time, like the guided flow.
/// The site's page is below the guide; the person finds the right page, taps "This is the page" (the page on screen is recorded), and may say what kind of form
/// it is and give an email address. Everything is kept in Documents/site-review.json and can be copied or shared as JSON from the … menu.
/// The same fields as the web review page (`tools/site_review_template.html`), so the two can be merged: d, tag, url, email, note, at.
@MainActor
final class SiteReview: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let domain: String
        let name: String
        let url: URL?
        let email: String?
        let why: String
    }
    struct Tag: Codable, Equatable {
        var d: String
        var tag: String            // ok | other-page | search-first | email | account | none | dead | skip
        var url: String?
        var email: String?
        var note: String?
        var at: String
    }
    enum Kind: String, CaseIterable, Identifiable {
        case form, searchFirst, email, account, none, dead
        var id: String { rawValue }
        var label: String {
            switch self {
            case .form: return "A form on this page"
            case .searchFirst: return "Search for my record first"
            case .email: return "Email only"
            case .account: return "Needs login, ID or phone"
            case .none: return "No online opt-out"
            case .dead: return "Site gone or broken"
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var tags: [String: Tag] = [:]
    @Published var index = 0
    let file: URL

    init(entries: [DirectoryEntry]) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = docs.appendingPathComponent("site-review.json")
        rows = Self.rows(from: entries)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Tag].self, from: data) {
            tags = Dictionary(saved.map { ($0.d, $0) }, uniquingKeysWith: { a, b in a.at >= b.at ? a : b })
        }
        index = rows.firstIndex { !isDone($0) } ?? 0
    }

    /// The sites to go through: no readable form (or one that asks for business details), most important first.
    static func rows(from entries: [DirectoryEntry]) -> [Row] {
        entries.filter { e in
            guard e.excluded == nil, e.closed == nil, e.optOutForm == nil else { return false }
            if let live = e.liveForm, live.found, !live.blockers.contains("business") { return false }
            return true
        }
        .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }
        .map { e in
            let business = e.liveForm?.blockers.contains("business") ?? false
            let why = business ? "A form on its page asks for business details" : (e.optOutURL != nil ? "Its page has no form the app can read" : "No opt-out page on file")
            return Row(id: e.id, domain: e.domain, name: e.name, url: e.optOutURL, email: e.contactEmail, why: why)
        }
    }

    var current: Row? { rows.indices.contains(index) ? rows[index] : nil }
    func isDone(_ r: Row) -> Bool { if let t = tags[r.domain] { return t.tag != "skip" } else { return false } }
    var doneCount: Int { rows.filter(isDone).count }

    func record(_ t: Tag, advance: Bool = true) {
        tags[t.d] = t
        save()
        if advance { next() }
    }
    func next() {
        guard !rows.isEmpty else { return }
        for step in 1...rows.count {
            let i = (index + step) % rows.count
            if !isDone(rows[i]) { index = i; return }
        }
    }
    func back() { if index > 0 { index -= 1 } }

    func json() -> String {
        let all = tags.values.sorted { $0.d < $1.d }
        guard let data = try? JSONEncoder().encode(all), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
    private func save() { try? Data(json().utf8).write(to: file, options: .atomic) }

    /// Merges tags from the web review page ("Copy all tags as JSON"), so sites already tagged there are not asked about again. The newer one of two wins.
    @discardableResult func importJSON(_ text: String) -> Int {
        guard let data = text.data(using: .utf8), let incoming = try? JSONDecoder().decode([Tag].self, from: data) else { return 0 }
        var n = 0
        for t in incoming where tags[t.d] == nil || (tags[t.d]?.at ?? "") < t.at { tags[t.d] = t; n += 1 }
        save()
        if let c = current, isDone(c) { next() }
        return n
    }
}

/// A plain web view the person can use, with its address kept up to date.
@MainActor
final class ReviewBrowser: ObservableObject {
    let web: WKWebView = {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.allowsBackForwardNavigationGestures = true
        return w
    }()
    @Published var address = ""
    private var watch: NSKeyValueObservation?
    init() { watch = web.observe(\.url, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.address = w.url?.absoluteString ?? "" } } }
    func load(_ url: URL) { web.load(URLRequest(url: url)) }
}

struct SiteReviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var review: SiteReview
    @StateObject private var browser = ReviewBrowser()
    @Preference("guide.collapsed") private var collapsed = false
    @State private var kind: SiteReview.Kind = .form
    @State private var email = ""
    @State private var note = ""
    @State private var message = ""

    init(entries: [DirectoryEntry]) { _review = StateObject(wrappedValue: SiteReview(entries: entries)) }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                GuideSurface(topInset: geo.safeAreaInsets.top) { header }
                GuideBoundary()
                WebViewHost(webView: browser.web).frame(maxHeight: .infinity)
            }
            .ignoresSafeArea(edges: .top)
        }
        .onAppear { loadCurrent() }
        .onChange(of: review.current?.id) { _, _ in loadCurrent() }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            Menu {
                if let r = review.current {
                    Button { browser.load(URL(string: "https://\(r.domain)")!) } label: { Label("Open the site", systemImage: "house") }
                    Button { if let u = r.url { browser.load(u) } } label: { Label("Open the page we have", systemImage: "link") }.disabled(r.url == nil)
                    Button {
                        let q = "\(r.domain) opt out do not sell my personal information".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? r.domain
                        browser.load(URL(string: "https://duckduckgo.com/?q=\(q)")!)
                    } label: { Label("Search for the opt-out page", systemImage: "magnifyingglass") }
                    Button { browser.web.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button { UIPasteboard.general.string = browser.address } label: { Label("Copy this page's address", systemImage: "doc.on.doc") }
                    Divider()
                    Button { tag("none") } label: { Label("No online opt-out", systemImage: "xmark.circle") }
                    Button { tag("dead") } label: { Label("Site gone or broken", systemImage: "bolt.slash") }
                    Button { review.record(.init(d: r.domain, tag: "skip", url: nil, email: nil, note: nil, at: now()))  } label: { Label("Skip for now", systemImage: "forward") }
                    Button { review.back() } label: { Label("Previous site", systemImage: "backward") }
                    Divider()
                }
                Button { UIPasteboard.general.string = review.json(); message = "Copied \(review.tags.count) tags as JSON." } label: { Label("Copy all tags as JSON", systemImage: "square.and.arrow.up") }
                ShareLink(item: review.json()) { Label("Share all tags", systemImage: "square.and.arrow.up.on.square") }
                Button {
                    let n = review.importJSON(UIPasteboard.general.string ?? "")
                    message = "Imported \(n) tags from the clipboard."
                } label: { Label("Import tags from the clipboard", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { dismiss() } label: { Label("Close", systemImage: "xmark") }
            } label: { Image(systemName: "ellipsis.circle").font(.title2) }
            Button { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } } label: { Image(systemName: collapsed ? "chevron.down.circle" : "chevron.up.circle").font(.title2) }
            Text(verbatim: review.current.map { $0.domain } ?? "All done").font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).layoutPriority(-1)
            Text(verbatim: "\(review.index + 1)/\(review.rows.count)").font(.caption.bold()).foregroundStyle(.white.opacity(0.6)).fixedSize()
            Spacer(minLength: 4)
            Button { thisIsThePage() } label: { Text(verbatim: "This is the page") }.buttonStyle(GuidePrimaryStyle()).disabled(review.current == nil)
        }
        if !collapsed, let r = review.current {
            Text(verbatim: "\(r.name)  ·  \(review.doneCount) of \(review.rows.count) done").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Text(verbatim: r.why).font(.caption).foregroundStyle(Color.exnayGold).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: browser.address).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Text(verbatim: "Kind").font(.caption).foregroundStyle(.white.opacity(0.7))
                Picker("Kind", selection: $kind) { ForEach(SiteReview.Kind.allCases) { Text(verbatim: $0.label).tag($0) } }.pickerStyle(.menu)
                Spacer()
            }
            TextField("Email to write to (optional)", text: $email).textFieldStyle(.roundedBorder).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Note (optional)", text: $note).textFieldStyle(.roundedBorder)
            if !message.isEmpty { Text(verbatim: message).font(.caption).foregroundStyle(Color.green) }
        }
    }

    private func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    private func loadCurrent() {
        guard let r = review.current else { return }
        let t = review.tags[r.domain]
        kind = .form; email = t?.email ?? ""; note = t?.note ?? ""
        browser.load(r.url ?? URL(string: "https://\(r.domain)")!)
    }

    private func thisIsThePage() {
        guard let r = review.current else { return }
        let page = browser.address
        var tag = "ok"
        switch kind {
        case .form: tag = (r.url?.absoluteString == page) ? "ok" : "other-page"
        case .searchFirst: tag = "search-first"
        case .email: tag = "email"
        case .account: tag = "account"
        case .none: tag = "none"
        case .dead: tag = "dead"
        }
        review.record(.init(d: r.domain, tag: tag, url: page, email: email.isEmpty ? nil : email, note: note.isEmpty ? nil : note, at: now()))
        message = "Saved \(r.domain)."
    }

    private func tag(_ key: String) {
        guard let r = review.current else { return }
        review.record(.init(d: r.domain, tag: key, url: nil, email: email.isEmpty ? nil : email, note: note.isEmpty ? nil : note, at: now()))
    }
}
#endif
