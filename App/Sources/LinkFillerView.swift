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
    let sentQuestion = SentQuestion()
    /// Bumped when the person cancels (or another page is opened): a load still running for an older number stops quietly.
    private var generation = 0

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

    /// The person gave up waiting for the page: it is dropped and the link box comes back.
    func cancelLoading() { generation += 1; close(); busy = false }

    /// How long a page may take before it is shown as it is (a page that keeps loading in the background, or never reports that it finished).
    static let loadSeconds: TimeInterval = 30

    func open(_ url: URL) async {
        close(); generation += 1; let mine = generation
        busy = true; host = url.host ?? ""
        status = Loc.t("Loading the page…")
        let s = WebViewSession.make(); session = s
        do { try await s.load(URLRequest(url: url), within: Self.loadSeconds) } catch {
            guard mine == generation else { return }
            status = Loc.t("The page would not load. Check the link and try again."); busy = false; return
        }
        guard mine == generation else { return }
        await s.settlePage(maxWait: 10)
        guard mine == generation else { return }
        _ = await s.denyCookies()
        guard mine == generation else { return }
        webView = s.presentable()
        status = Loc.t("The page is loaded. Check the address above, then choose \"Fill in my details\" in the … menu.")
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
            status = Loc.t("No form found on this page. If it needs a click first, do that in the page, then choose \"Fill in my details\" in the … menu again.")
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
        return await PageSender.sendWhenReady(page: page, autoSubmit: autoSubmit, status: { [weak self] in self?.status = $0 }, isCancelled: isCancelled, stillCurrent: { [weak self] in self?.session === s }, question: sentQuestion)
    }

    func pageText() async -> String { await session?.viewportText() ?? "" }
    /// The address of the page on screen.
    var currentURL: URL? { session?.webView.url }

    func close() { sentQuestion.dismiss(); page = nil; session?.close(); session = nil; webView = nil; host = ""; status = "" }
}

struct LinkFillerView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var filler = LinkFiller()
    @State private var text = ""
    @State private var check: LinkCheck?
    @State private var asking: (url: URL, check: LinkCheck)?
    /// A link that could be several sites, or none we know: the person is choosing which.
    @State private var choosing: PendingLink?
    /// The person named the site for this link; `pickedTrusted` is whether the link's address is one that site is known by.
    @State private var picked = false
    @State private var pickedTrusted = true
    @State private var showTour = false
    @State private var finished = false
    @State private var showDone = false
    @StateObject private var browserHandoff = BrowserHandoff()
    @StateObject private var finishQuestion = FinishQuestion()
    @AppStorage("guide.collapsed") private var guideCollapsed = false
    var startLink: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if filler.webView == nil { chooser }
                if let web = filler.webView { loaded(web) }
                else if !filler.status.isEmpty { guideText(filler.status).font(.footnote).foregroundStyle(.secondary).padding() }
            }
            .navigationTitle("Email links")
            .toolbarColorScheme(filler.webView != nil ? .dark : nil, for: .navigationBar)          // the guide above the page is black: the title stays readable on it
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showTour = true } label: { Image(systemName: "questionmark.circle") }.accessibilityLabel("How this works") } }
        }
        .overlay { if filler.busy, filler.webView == nil { LoadingMark(title: Loc.t("Loading the page…"), cancel: { filler.cancelLoading(); returnToChooser() }).transition(.opacity) } }
        .onChange(of: model.incomingLink) { _, _ in takeIncomingLink() }
        // The link waits for the sheet to be gone, and a moment more: a sheet or a question asked while the last one is still sliding away is dropped.
        .onChange(of: model.coveredByASheet) { _, covered in if !covered { Task { try? await Task.sleep(nanoseconds: 800_000_000); takeIncomingLink() } } }
        .overlay { if showDone { SentCheck().transition(.opacity) } }
        .onAppear { filler.autoSubmit = { model.autoSubmit } }
        .task(id: filler.webView == nil) { await watchForCompletion() }
        .sentQuestionAlert(filler.sentQuestion)
        .sheet(isPresented: $showTour, onDismiss: { model.markLinkFillerToured() }) { LinkFillerTour { showTour = false } }
        .sheet(item: $choosing) { pending in
            LinkSitePicker(pending: pending, directory: model.directory, waiting: Set(model.pendingFollowUps.map(\.entry.id)),
                           choose: { entry in pickSite(entry, for: pending) },
                           openAnyway: pending.url.map { url in { choosing = nil; open(url, pending.check, fill: false) } },
                           cancel: { choosing = nil; if pending.url != nil { returnToChooser() } })
        }
        // A site already marked finished: the link may still be right, when the email asked for more (a confirmation, another form, another step).
        .confirmationDialog(askTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible, presenting: asking) { a in
            Button("Yes, it needs more: open it") {
                if case .known(let id, _, _, _) = a.check { model.addFollowUpStep(id) }          // back on the waiting list until the extra step is done
                open(a.url, a.check)
            }.accessibilityIdentifier("link-needs-more")
            Button("It is a different site") { choosing = PendingLink(url: a.url, check: .unknown(host: a.url.host ?? "")) }
            Button("No, it is finished", role: .cancel) { returnToChooser() }
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
                                let steps = model.followUpStepsDone(item.entry.id)
                                if steps > 0 { Text(Loc.f("%lld email steps finished so far; waiting on the next", steps)).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            // Finishing a step: another may follow (a site can send several), so the person says which.
                            Menu("Done") {
                                Button("That was the last step") { model.markFollowUpDone(item.entry.id) }.accessibilityIdentifier("followup-last-\(item.entry.domain)")
                                Button("Done, and another email step is coming") { model.markFollowUpDone(item.entry.id); model.addFollowUpStep(item.entry.id) }.accessibilityIdentifier("followup-more-\(item.entry.domain)")
                            }.buttonStyle(.bordered).accessibilityIdentifier("followup-done-\(item.entry.domain)")
                        }
                    }
                } header: { Text("Waiting on an email") } footer: { Text("These sites said they would email you with more to do. Paste the link from that email above, or tap Done if you finished it another way.") }
            }
        }
    }

    /// The page, with the guide's controls above it in the same place and style as Solve and send: always at the top, so the page below can use the rest of the screen.
    private func loaded(_ web: WKWebView) -> some View {
        VStack(spacing: 0) {
            GuideSurface(topInset: 0, collapsed: $guideCollapsed) {
                HStack(spacing: 10) {
                    Menu {
                        PageMenu.items(web: web, fillTitle: "Fill in my details", idPrefix: "link", fillID: "fill", canFill: !filler.busy, details: model.pageDetails, browser: browserHandoff, anotherEmailStep: { if case .known(let id, _, _, _)? = check { model.addFollowUpStep(id) } }) {
                            if let me = model.selectedPerson { model.requireProfile { Task { await filler.fill(person: model.formPerson(me), termsPolicy: model.makeTermsPolicy()) } } }
                        }
                        Button(role: .destructive) { returnToChooser() } label: { Label("Change link", systemImage: "link") }.accessibilityIdentifier("link-change")
                    } label: { Image(systemName: "ellipsis.circle").font(.title2) }
                        .accessibilityLabel(Loc.t("More")).accessibilityIdentifier("link-more")
                    GuideCollapseButton(collapsed: $guideCollapsed)
                    Image(systemName: "lock.fill").foregroundStyle(.green).font(.caption)
                    Text(filler.host).font(.caption.bold()).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Spacer(minLength: 4)
                    markCompletedButton
                }
                if !guideCollapsed { matchLine }
                if !guideCollapsed, !filler.status.isEmpty {
                    guideText(filler.status).font(.caption).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("link-status")
                }
                if !guideCollapsed { AutoSubmitToggle() }
            }
            GuideBoundary()
            WebViewHost(webView: web)
        }
        .browserHandoffAlert(browserHandoff) { if case .known(let id, _, _, _)? = check { Task { await finish(id) } } else { returnToChooser() } }
        .finishQuestionAlert(finishQuestion)
    }

    /// Mark completed is always there: it finishes the request for the site the link matched. When the link is not matched to a site, it asks which site it is.
    private var markCompletedButton: some View {
        let matched: String? = { if case .known(let id, _, _, _)? = check { return id } else { return nil } }()
        return Button {
            if let matched { Task { await finish(matched) } }
            else { choosing = PendingLink(url: nil, check: check ?? .unknown(host: filler.host)) }
        } label: { Text("Mark completed") }
            .buttonStyle(GuideSecondaryStyle())
            .disabled(showDone).accessibilityIdentifier("link-finished")
    }

    @ViewBuilder private var matchLine: some View {
        if case .known(_, let name, _, _)? = check {
            if picked && !pickedTrusted {
                Label(Loc.f("You chose %@, but this link's address is not one we know for that site. Check the address above before you enter anything.", name), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("link-no-match")
            } else if picked {
                Label(Loc.f("You chose %@ for this link.", name), systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green).accessibilityIdentifier("link-match")
            } else {
                Label(Loc.f("This link matches %@, a site in your list.", name), systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green).accessibilityIdentifier("link-match")
            }
        } else {
            Button { choosing = PendingLink(url: nil, check: check ?? .unknown(host: filler.host)) } label: {
                Label("We could not tell which site this link is for. Tap to choose it.", systemImage: "questionmark.circle.fill")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("link-no-match")
        }
    }

    /// A link shared to Exnay from a mail app: any page that was open is closed, and the link is checked and opened as if it had been pasted.
    private func takeIncomingLink() {
        guard let link = model.incomingLink, !model.coveredByASheet else { return }          // under a sheet it waits (see onChange below)
        model.incomingLink = nil
        returnToChooser()
        text = link
        begin()
    }

    private func begin() {
        guard let url = LinkFiller.normalized(text) else { return }
        let c = model.checkLink(url)
        switch c {
        case .unknown, .shared: choosing = PendingLink(url: url, check: c)          // not guessed: the person says which site it is
        case .known(_, _, let done?, _) where done != nil: asking = (url, c)
        default: open(url, c)
        }
    }

    /// The person chose a site for the link. A link whose address that site is known by is filled in and sent as usual; any other address is only loaded.
    private func pickSite(_ entry: DirectoryEntry, for pending: PendingLink) {
        choosing = nil
        let c = model.linkState(for: entry)
        guard let url = pending.url else {          // "Mark completed" on a page that is already open
            check = c; picked = true; pickedTrusted = filler.currentURL.map { LinkCheck.verifies($0, for: entry) } ?? false
            Task { await finish(entry.id) }
            return
        }
        let trusted = LinkCheck.verifies(url, for: entry)
        if case .known(_, _, let done?, _) = c, done != nil, trusted { asking = (url, c); return }
        open(url, c, fill: trusted, picked: true, trusted: trusted)
    }

    /// Asks "Is it completely done?" first unless the page says with confidence that it is; "not yet" leaves the person where they are.
    private func finish(_ id: String) async {
        guard !showDone else { return }
        let text = await filler.pageText()
        if FormRun.finishIsCertain(text) { complete(id); return }
        let name = { if case .known(_, let n, _, _)? = check { return n } else { return filler.host } }()
        switch await finishQuestion.ask(site: name, pageSaidEmail: FormRun.mentionsEmailFollowUp(text), allowsNotYet: true) {
        case .done: complete(id)
        case .emailFollows, .unsure: complete(id, moreEmail: true)
        case .notYet: break
        }
    }

    /// The request is finished: the site leaves the waiting list, the green check shows, and the tab goes back to an empty link box.
    private func complete(_ id: String, moreEmail: Bool = false) {
        guard !showDone else { return }
        model.completeFromLink(id, moreEmail: moreEmail)
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
                // Finished with no word of an email: done. Finished but mentioning an email: asked, since another step may follow.
                if case .known(let id, _, _, _)? = check { if FormRun.finishIsCertain(added) { complete(id) } else { await finish(id) } }
                else { withAnimation { showDone = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { showDone = false }; returnToChooser() } }
                return
            }
        }
    }

    /// Closes the page and clears the pasted link so the tab is ready for the next one.
    private func returnToChooser() { filler.close(); check = nil; finished = false; text = ""; picked = false; pickedTrusted = true }

    private func open(_ url: URL, _ c: LinkCheck, fill: Bool = true, picked: Bool = false, trusted: Bool = true) {
        check = c; finished = false; self.picked = picked; pickedTrusted = trusted
        Task {
            await filler.open(url)
            if fill { await autoFinish() }          // a link for a site by hand at an address it is not known by is only loaded
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

    private var askTitle: String {
        guard let a = asking, case .known(_, let name, _, _) = a.check else { return "" }
        return Loc.f("%@ is already marked finished", name)
    }
    private func askMessage(_ c: LinkCheck) -> String {
        guard case .known(_, let name, let done, _) = c else { return "" }
        return Loc.f("A request to %@ was finished on %@. Does this link ask for more: a confirmation, another form or another step?", name, (done ?? Date()).formatted(date: .abbreviated, time: .omitted))
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
