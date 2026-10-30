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

    func fill(person: Person) async {
        guard let s = session else { return }
        busy = true; defer { busy = false }
        status = Loc.t("Filling in your details…")
        // A form already on the page is filled as it is. Only a page with no form gets its request chosen (plain "Opt Out" and "Delete" buttons, never links).
        var step: String?
        var forms = await s.discoverForms()
        if LiveFormPicker.pick(forms, pageContext: await s.pageContext()) == nil {
            step = await s.advanceToRequestForm(loose: true)
            forms = await s.discoverForms()
        }
        guard let form = LiveFormPicker.pick(forms, pageContext: await s.pageContext()) else {
            if let confirm = await s.confirmButtonLabel() { status = Loc.f("This page only needs your confirmation. Read it, then press \"%@\" yourself.", confirm); return }
            status = step != nil ? Loc.f("We chose \"%@\" for you. Read the page and confirm with its own button.", step ?? "")
                                 : Loc.t("No form found on this page. If it needs a click first, do that in the page, then tap Fill in my details again.")
            return
        }
        s.chosenForm = form.token
        let plan = FormFiller.plan(for: form.asOptOutForm(page: webView?.url ?? URL(string: "https://invalid.example")!), signals: nil, person: person)
        switch plan.verdict {
        case .ready: break
        case .needsData(let what): status = Loc.f("The form asks for %@, which we do not hold. Add it to your profile.", what.joined(separator: ", ")); return
        case .needsYou(let why): status = why; return
        }
        let fill = await s.fillLive(plan.values, keepExisting: true)
        _ = await s.chooseRequestOptions(form: form.token, ownerMayConfirm: person.mayConfirmOwnIdentity())
        _ = await s.chooseCustomMenus(state: USStates.name(for: person.currentAddress?.state ?? ""))
        await s.scrollFormIntoView(form.token)
        #if DEBUG
        // Simulator work: what every visible field held after the fill, written to Documents/linkfill.json.
        if let json = try? await s.webView.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('input,select,textarea')].filter(e=>e.getBoundingClientRect().width>0&&!['hidden','submit','button'].includes(e.type)).map(e=>({label:((e.id&&document.querySelector('label[for=\"'+e.id+'\"]')||e.closest('label')||{}).innerText||e.placeholder||e.name||'').trim().slice(0,50),type:e.type,value:(e.tagName==='SELECT'?(e.options[e.selectedIndex]||{}).text:e.type==='checkbox'?String(e.checked):e.value)||''})))") as? String,
           let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { try? json.write(to: docs.appendingPathComponent("linkfill.json"), atomically: true, encoding: .utf8) }
        #endif
        status = fill.filled == 0 ? Loc.t("The form's fields could not be filled in. Fill it in the page yourself.")
            : Loc.f("Filled in %lld fields. Check them, solve any check, then press the page's own button to send.", fill.filled)
    }

    func close() { session?.close(); session = nil; webView = nil; host = ""; status = "" }
}

struct LinkFillerView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var filler = LinkFiller()
    @State private var text = ""
    @State private var check: LinkCheck?
    @State private var asking: (url: URL, check: LinkCheck)?
    @State private var showTour = false
    @State private var finished = false
    var startLink: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if filler.webView == nil { chooser }
                if let web = filler.webView { loaded(web) }
                else if !filler.status.isEmpty { Text(filler.status).font(.footnote).foregroundStyle(.secondary).padding() }
            }
            .navigationTitle("Email links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showTour = true } label: { Image(systemName: "questionmark.circle") }.accessibilityLabel("How this works") } }
        }
        .overlay { if filler.busy, filler.webView == nil { LoadingMark(title: Loc.t("Loading the page…")).transition(.opacity) } }
        .sheet(isPresented: $showTour, onDismiss: { model.markLinkFillerToured() }) { LinkFillerTour { showTour = false } }
        .confirmationDialog(askTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible, presenting: asking) { a in
            Button(isUnknown(a.check) ? "Open it anyway" : "Open it again", role: isUnknown(a.check) ? .destructive : nil) { open(a.url, a.check) }
            Button("Don't open", role: .cancel) {}
        } message: { a in Text(askMessage(a.check)) }
        .onAppear {
            if model.shouldTourLinkFiller, startLink.isEmpty { showTour = true }
            if !startLink.isEmpty, text.isEmpty {
                text = startLink
                if let url = LinkFiller.normalized(startLink) {
                    Task {
                        check = model.checkLink(url)
                        await filler.open(url)
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("-auto-fill"), let me = model.selectedPerson { await filler.fill(person: model.formPerson(me)) }
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

    private func loaded(_ web: WKWebView) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text(filler.host).font(.subheadline.bold()).lineLimit(1)
                Spacer()
                Button("Change link") { returnToChooser() }.font(.subheadline)
            }.padding(.horizontal).padding(.vertical, 8).background(.bar)
            if case .known(_, let name, _, _)? = check {
                Label(Loc.f("This link matches %@, a site in your list.", name), systemImage: "checkmark.seal.fill").font(.footnote).foregroundStyle(.green).padding(.vertical, 6)
            } else if case .unknown? = check {
                Label("This link is not from a site in your list. Be careful what you enter.", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange).padding(.vertical, 6)
            }
            WebViewHost(webView: web)
            VStack(spacing: 8) {
                Text(filler.status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button {
                    if let me = model.selectedPerson { model.requireProfile { Task { await filler.fill(person: model.formPerson(me)) } } }
                } label: { Label("Fill in my details", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(filler.busy).accessibilityIdentifier("link-fill")
                if case .known(let id, _, _, let waiting)? = check, waiting, !finished {
                    Button { model.markFollowUpDone(id); returnToChooser() } label: { Label("I finished this request", systemImage: "checkmark.circle").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }.padding()
        }
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

    /// Closes the page and clears the pasted link so the tab is ready for the next one.
    private func returnToChooser() { filler.close(); check = nil; finished = false; text = "" }

    private func open(_ url: URL, _ c: LinkCheck) { check = c; finished = false; Task { await filler.open(url) } }

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
        ("checkmark.shield", Loc.t("We check it first"), Loc.t("We make sure the link is from a site in your list and tell you if it is not, or if you already finished that site. Then we load the page and fill in your details.")),
        ("hand.tap", Loc.t("You press the last button"), Loc.t("Read the page, clear any check, and press its own button. We never send it for you. Tap \"I finished this request\" when you are done."))
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
