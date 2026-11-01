import SwiftUI
import WebKit
import OptOutKitCore

/// Finish a request from an email: the person pastes the link, the page loads, and the form on it is filled in from their details. The person checks the
/// page, solves any check and presses the page's own button; nothing is sent for them.
@MainActor
final class LinkFiller: ObservableObject {
    @Published var status = ""
    @Published var webView: WKWebView?
    @Published var host = ""
    @Published var busy = false
    private var session: WebViewSession?

    /// A web address from pasted text: https only (an http link is upgraded), with a real host.
    static func normalized(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard var c = URLComponents(string: t), let host = c.host, host.contains(".") else { return nil }
        if c.scheme == "http" { c.scheme = "https" }
        return c.scheme == "https" ? c.url : nil
    }

    /// Test hook: works on a session that already holds a page.
    func attach(_ session: WebViewSession) { close(); self.session = session; webView = session.presentable(); host = "test" }

    func open(_ url: URL) async {
        close(); busy = true; host = url.host ?? ""
        status = Loc.t("Loading the page…")
        let s = WebViewSession.make(); session = s
        do { try await s.load(URLRequest(url: url)) } catch { status = Loc.t("The page would not load. Check the link and try again."); busy = false; return }
        await s.settlePage(maxWait: 10)
        _ = await s.denyCookies()
        webView = s.presentable()
        status = Loc.t("The page is loaded. Check the address above, then tap \"Fill in my details\".")
        busy = false
    }

    /// Asked when it is time to send: whether the app presses the page's own send button (the person's "Send it for me" choice).
    var autoSubmit: () -> Bool = { true }
    private var page: AssistedPage?
    private var pageURL: URL?

    /// The page's forms are found, answered and filled in by the same code Solve and send uses (`WebAssistedDriver`), so a portal one can handle the other can too:
    /// a type-ahead state, questions that appear as others are answered, several forms on one page, tiles, a device ID, terms.
    @discardableResult
    func fill(person: Person, termsPolicy: TermsPolicy? = nil) async -> Bool {
        guard let s = session else { return false }
        busy = true; defer { busy = false }
        status = Loc.t("Filling in your details…")
        let url = s.webView.url ?? URL(string: "https://invalid.example")!
        pageURL = url
        let driver = WebAssistedDriver(person: person, advertisingID: nil, termsPolicy: termsPolicy)
        let stand = OptOutForm(page: url, method: "post", action: nil, fields: [], hops: 1)
        guard let prepared = await driver.prepareLoaded(session: s, form: stand, plan: FillPlan(values: [], verdict: .ready), keepOpenWithoutForm: true, advanceOnlyWithoutForm: true) else {
            if let confirm = await s.confirmButtonLabel() { status = Loc.f("This page only needs your confirmation. Read it, then press \"%@\" yourself.", confirm); return false }
            status = Loc.t("No form found on this page. If it needs a click first, do that in the page, then tap Fill in my details again.")
            return false
        }
        page = prepared
        await s.scrollChallengeIntoView()
        #if DEBUG
        // Simulator work: what every visible field held after the fill, written to Documents/linkfill.json.
        if let json = try? await s.webView.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('input,select,textarea')].filter(e=>e.getBoundingClientRect().width>0&&!['hidden','submit','button'].includes(e.type)).map(e=>({id:e.id||e.name||'',type:e.type||e.tagName,value:e.value})))") as? String,
           let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { try? json.write(to: docs.appendingPathComponent("linkfill.json"), atomically: true, encoding: .utf8) }
        #endif
        status = autoSubmit() ? Loc.t("Your details are filled in. Check them, solve any check, and we will send it.")
                              : Loc.t("Your details are filled in. Check them, solve any check, then press the page's own button to send.")
        return true
    }

    /// Sends the page's opt-out forms (see `PageSender`). Nil while it is still waiting or if it was stopped; the result once sent.
    func sendWhenReady(isCancelled: @escaping () -> Bool) async -> SubmitOutcome? {
        guard let s = session, let page else { return nil }
        return await PageSender.sendWhenReady(page: page, autoSubmit: autoSubmit, status: { [weak self] in self?.status = $0 }, isCancelled: isCancelled, stillCurrent: { [weak self] in self?.session === s })
    }

    func pageText() async -> String { await session?.viewportText() ?? "" }

    func close() { page = nil; session?.close(); session = nil; webView = nil; host = ""; status = "" }
}

struct LinkFillerView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var filler = LinkFiller()
    @State private var text = ""
    @State private var check: LinkCheck?
    @State private var asking: (url: URL, check: LinkCheck)?
    @State private var showTour = false
    @State private var finished = false
    @State private var showDone = false
    var startLink: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if filler.webView == nil { chooser }
                if let web = filler.webView { loaded(web) }
                else if !filler.status.isEmpty { Text(filler.status).font(.footnote).foregroundStyle(.secondary).padding() }
            }
            .navigationTitle("Email links")
            .toolbarColorScheme(filler.webView != nil ? .dark : nil, for: .navigationBar)          // the guide above the page is black: the title stays readable on it
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showTour = true } label: { Image(systemName: "questionmark.circle") }.accessibilityLabel("How this works") } }
        }
        .overlay { if filler.busy, filler.webView == nil { LoadingMark(title: Loc.t("Loading the page…")).transition(.opacity) } }
        .onChange(of: model.incomingLink) { _, _ in takeIncomingLink() }
        .overlay { if showDone { SentCheck().transition(.opacity) } }
        .onAppear { filler.autoSubmit = { model.autoSubmit } }
        .task(id: filler.webView == nil) { await watchForCompletion() }
        .sheet(isPresented: $showTour, onDismiss: { model.markLinkFillerToured() }) { LinkFillerTour { showTour = false } }
        .confirmationDialog(askTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible, presenting: asking) { a in
            Button(isUnknown(a.check) ? "Open it anyway" : "Open it again", role: isUnknown(a.check) ? .destructive : nil) { open(a.url, a.check) }
            Button("Don't open", role: .cancel) {}
        } message: { a in Text(askMessage(a.check)) }
        .onAppear {
            if model.incomingLink != nil { takeIncomingLink() }
            else if model.shouldTourLinkFiller, startLink.isEmpty { showTour = true }
            if !startLink.isEmpty, text.isEmpty {
                text = startLink
                if let url = LinkFiller.normalized(startLink) {
                    Task {
                        check = model.checkLink(url)
                        await filler.open(url)
                        await autoFinish()
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("-auto-fill"), let me = model.selectedPerson { await filler.fill(person: model.formPerson(me), termsPolicy: model.makeTermsPolicy()) }
                        #endif
                    }
                }
            }
        }
        .onDisappear { returnToChooser() }
    }

    private var chooser: some View {
        Form {
            Section {
                Text("Some opt-outs end with an email: a link to confirm or to finish a form. Copy that link from the email, paste it here, and we check it and fill in your details.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Or skip the copying: press and hold the link in your mail app, tap Share, and choose Exnay. It opens here and loads the page.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    TextField("Paste the link from the email", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("link-field")
                    // The system's own paste button: reading the clipboard from code makes iOS ask "Allow Paste?" every time; this does not.
                    PasteButton(payloadType: String.self) { strings in if let s = strings.first { text = s; begin() } }
                        .labelStyle(.titleOnly).buttonBorderShape(.capsule).accessibilityIdentifier("link-paste")
                }
                Button { begin() } label: { Label("Check the link", systemImage: "link") }
                    .disabled(LinkFiller.normalized(text) == nil || filler.busy).accessibilityIdentifier("link-open")
            }
            let waiting = model.pendingFollowUps
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting, id: \.entry.id) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.entry.name).font(.body)
                                Text(Loc.f("Sent %@; look for their email", item.since.formatted(date: .abbreviated, time: .omitted))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Done") { model.markFollowUpDone(item.entry.id) }.buttonStyle(.bordered)
                        }
                    }
                } header: { Text("Waiting on an email") } footer: { Text("These sites said they would email you with more to do. Paste the link from that email above, or tap Done if you finished it another way.") }
            }
        }
    }

    /// The page, with the guide's controls above it in the same place and style as Solve and send: always at the top, so the page below can use the rest of the screen.
    private func loaded(_ web: WKWebView) -> some View {
        VStack(spacing: 0) {
            GuideSurface(topInset: 0) {
                HStack(spacing: 10) {
                    Menu {
                        Button { web.reload() } label: { Label("Refresh the page", systemImage: "arrow.clockwise") }.accessibilityIdentifier("link-refresh")
                        Button(role: .destructive) { returnToChooser() } label: { Label("Change link", systemImage: "link") }.accessibilityIdentifier("link-change")
                    } label: { Image(systemName: "ellipsis.circle").font(.title2) }
                        .accessibilityLabel(Loc.t("More")).accessibilityIdentifier("link-more")
                    Image(systemName: "lock.fill").foregroundStyle(.green).font(.caption)
                    Text(filler.host).font(.caption.bold()).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        if let me = model.selectedPerson { model.requireProfile { Task { await filler.fill(person: model.formPerson(me), termsPolicy: model.makeTermsPolicy()) } } }
                    } label: { Text("Fill in my details") }
                        .buttonStyle(GuidePrimaryStyle()).disabled(filler.busy).opacity(filler.busy ? 0.5 : 1).accessibilityIdentifier("link-fill")
                }
                matchLine
                if !filler.status.isEmpty {
                    Text(filler.status).font(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("link-status")
                }
                HStack(spacing: 12) {
                    markCompletedButton
                    AutoSubmitToggle()
                }
            }
            GuideBoundary()
            WebViewHost(webView: web)
        }
    }

    /// Mark completed is always there: it finishes the request for the site the link matched, or it is dimmed and the line below says why it cannot.
    private var markCompletedButton: some View {
        let matched: String? = { if case .known(let id, _, _, _)? = check { return id } else { return nil } }()
        return Button { if let matched { complete(matched) } } label: { Label("Mark completed", systemImage: "checkmark.circle") }
            .buttonStyle(GuidePillStyle(filled: false))
            .disabled(matched == nil || showDone).opacity(matched == nil ? 0.45 : 1).accessibilityIdentifier("link-finished")
    }

    @ViewBuilder private var matchLine: some View {
        if case .known(_, let name, _, _)? = check {
            Label(Loc.f("This link matches %@, a site in your list.", name), systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green).accessibilityIdentifier("link-match")
        } else {
            Label("No match: this link is not from a site in your list, so there is nothing to mark completed. Be careful what you enter.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("link-no-match")
        }
    }

    /// A link shared to Exnay from a mail app: any page that was open is closed, and the link is checked and opened as if it had been pasted.
    private func takeIncomingLink() {
        guard let link = model.incomingLink else { return }
        model.incomingLink = nil
        returnToChooser()
        text = link
        begin()
    }

    private func begin() {
        guard let url = LinkFiller.normalized(text) else { return }
        let c = model.checkLink(url)
        switch c {
        case .unknown: asking = (url, c)
        case .known(_, _, let done?, _) where done != nil: asking = (url, c)
        default: open(url, c)
        }
    }

    /// The request is finished: the site leaves the waiting list, the green check shows, and the tab goes back to an empty link box.
    private func complete(_ id: String) {
        guard !showDone else { return }
        model.completeFromLink(id)
        withAnimation { showDone = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { showDone = false }; returnToChooser() }
    }

    /// While a link's page is open, reads it for a "removal complete" kind of message and finishes the request by itself when it appears.
    private func watchForCompletion() async {
        guard filler.webView != nil else { return }
        var baseline = await filler.pageText()
        while !Task.isCancelled, filler.webView != nil, !showDone {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let now = await filler.pageText()
            guard !now.isEmpty, now != baseline else { continue }
            let added = FormRun.newText(before: baseline, after: now)
            baseline = now
            if FormRun.looksFinished(added) {
                if case .known(let id, _, _, _)? = check { complete(id) }
                else { withAnimation { showDone = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { showDone = false }; returnToChooser() } }
                return
            }
        }
    }

    /// Closes the page and clears the pasted link so the tab is ready for the next one.
    private func returnToChooser() { filler.close(); check = nil; finished = false; text = "" }

    private func open(_ url: URL, _ c: LinkCheck) {
        check = c; finished = false
        Task {
            await filler.open(url)
            await autoFinish()
        }
    }

    /// For a link from a site in the list: fill the form in, wait for the person to clear any check, send it, and finish the request on a confirmation.
    /// A link from an unknown site is only loaded; filling and sending stay the person's call.
    private func autoFinish() async {
        guard filler.webView != nil, case .known(let id, _, _, _)? = check, let me = model.selectedPerson, model.isReady(me) else { return }
        guard await filler.fill(person: model.formPerson(me), termsPolicy: model.makeTermsPolicy()) else { return }
        let gone = { [filler] in filler.webView == nil }
        if case .submitted? = await filler.sendWhenReady(isCancelled: gone) { complete(id) }
    }

    private func isUnknown(_ c: LinkCheck) -> Bool { if case .unknown = c { return true } else { return false } }
    private var askTitle: String {
        guard let a = asking else { return "" }
        if case .known(_, let name, _, _) = a.check { return Loc.f("You already finished %@", name) }
        return Loc.t("We do not recognize this link")
    }
    private func askMessage(_ c: LinkCheck) -> String {
        switch c {
        case .unknown(let host): return Loc.f("%@ is not a site in your list, so it may not be from an opt-out you started. Only open it if you are sure.", host)
        case .known(_, let name, let done, _):
            return Loc.f("A request to %@ was finished on %@. You usually do not need this link again.", name, (done ?? Date()).formatted(date: .abbreviated, time: .omitted))
        }
    }
}

/// Shown the first time the tab opens, and from its help button.
struct LinkFillerTour: View {
    var done: () -> Void
    @State private var page = 0
    private let pages: [(icon: String, title: String, body: String)] = [
        ("envelope.open", Loc.t("Some opt-outs finish by email"), Loc.t("After you send a request, some sites email you a link to confirm it or to finish a form. Until you open that link, the request is not done. The app keeps a list of the ones waiting.")),
        ("doc.on.clipboard", Loc.t("Copy the link from the email"), Loc.t("Open the email, press and hold the button or link, and choose Copy Link. Then come back here and tap Paste.")),
        ("square.and.arrow.up", Loc.t("Or share it to Exnay"), Loc.t("In Gmail or another mail app, press and hold the link, tap Share, and choose Exnay. The app opens on this tab and loads the page. If Exnay is not in the list, scroll the share sheet to More. If it only copies the link, open Exnay and tap Paste.")),
        ("checkmark.shield", Loc.t("We check it first"), Loc.t("We make sure the link is from a site in your list and tell you if it is not, or if you already finished that site. Then we load the page and fill in your details.")),
        ("hand.tap", Loc.t("You clear the check"), Loc.t("We fill in the page and wait while you read it and clear any check or terms. Then we press its send button and watch for the confirmation. If it needs one more step, do it in the page and tap \"I finished this request\"."))
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 16) {
                        Image(systemName: pages[i].icon).font(.system(size: 56)).foregroundStyle(.tint)
                        Text(pages[i].title).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(pages[i].body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(.horizontal, 32).tag(i)
                }
            }.tabViewStyle(.page)
            Button { if page < pages.count - 1 { withAnimation { page += 1 } } else { done() } } label: {
                Text(page < pages.count - 1 ? "Next" : "Got it").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 32).padding(.bottom, 24)
        }.padding(.top, 48).presentationDetents([.large])
    }
}

/// Shown once, the first time a request is sent that needs an email check: why, and how the Email links tab finishes it.
struct EmailCheckExplainer: View {
    var openTab: (() -> Void)?
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "envelope.badge.shield.half.filled").font(.system(size: 52)).foregroundStyle(.tint).frame(maxWidth: .infinity)
                Text("This site hasn't opted you out yet").font(.title2.bold()).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                Group {
                    Text("They need one more step from you: you have to click a link they email you, and the page it opens may ask for more information. Until you do, **nothing is removed**.")
                    Text("We keep track of these").font(.headline)
                    Text("Every request waiting on an email is listed in the **Email links** tab, and the number on its icon shows how many.")
                    Text("When the email arrives").font(.headline)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Look for it in your inbox, and in spam or promotions. Some links expire after a day, so do it soon.", systemImage: "envelope")
                        Label("Don't tap the link in the email. Press and hold the link and choose Copy Link.", systemImage: "doc.on.clipboard")
                        Label("Open the Email links tab in Exnay and paste it.", systemImage: "link")
                        Label("Or choose Share, then Exnay, to open the link here without pasting.", systemImage: "square.and.arrow.up")
                    }
                    Text("Why paste it here instead of tapping it").font(.headline)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("1. We check that the link is safe: that it really belongs to the site you opted out of.", systemImage: "checkmark.shield")
                        Label("2. We fill in anything the page asks for, with your details, so you only press its final button. Then tap \"I finished this request\" and it leaves the list.", systemImage: "square.and.pencil")
                    }
                }
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                if let openTab {
                    Button { openTab() } label: { Label("Show me the Email links tab", systemImage: "envelope.open").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).accessibilityIdentifier("email-explainer-open")
                }
            }
            .padding(24)
        }
        // Pinned under the text, so it is always in reach however long the text runs.
        Button("Got it", action: done).buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 12)
            .accessibilityIdentifier("email-explainer-done")
        }
        .presentationDetents([.large])
    }
}
