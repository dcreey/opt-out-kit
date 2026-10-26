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
        _ = await s.chooseCustomMenus()
        await s.scrollFormIntoView(form.token)
        #if DEBUG
        // Simulator work: what every visible field held after the fill, written to Documents/linkfill.json.
        if let json = try? await s.webView.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('input,select,textarea')].filter(e=>e.getBoundingClientRect().width>0&&!['hidden','submit','button'].includes(e.type)).map(e=>({label:((e.id&&document.querySelector('label[for=\"'+e.id+'\"]')||e.closest('label')||{}).innerText||e.placeholder||e.name||'').trim().slice(0,50),type:e.type,value:(e.tagName==='SELECT'?(e.options[e.selectedIndex]||{}).text:e.type==='checkbox'?String(e.checked):e.value)||''})))") as? String,
           let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { try? json.write(to: docs.appendingPathComponent("linkfill.json"), atomically: true, encoding: .utf8) }
        #endif
        status = fill.filled == 0 ? Loc.t("The form's fields could not be filled in. Fill it in the page yourself.")
            : Loc.f("Filled in %lld fields. Check them, solve any check, then press the page's own button to send.", fill.filled)
    }

    func close() { session?.close(); session = nil; webView = nil; host = "" }
}

struct LinkFillerView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var filler = LinkFiller()
    @State private var text = ""
    var startLink: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if filler.webView == nil { Form {
                Section {
                    Text("Some opt-outs end with an email: a link to confirm or to finish a form. Paste that link here and we load the page and fill in your details. Only open links from emails you asked for.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        TextField("Paste the link from the email", text: $text)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("link-field")
                        Button("Paste") { if let s = UIPasteboard.general.string { text = s } }.buttonStyle(.bordered)
                    }
                    Button { if let url = LinkFiller.normalized(text) { Task { await filler.open(url) } } } label: { Label("Open the page", systemImage: "link") }
                        .disabled(LinkFiller.normalized(text) == nil || filler.busy).accessibilityIdentifier("link-open")
                }
            } }
            if let web = filler.webView {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.green)
                    Text(filler.host).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Button("Change link") { filler.close() }.font(.subheadline)
                }.padding(.horizontal).padding(.vertical, 8).background(.bar)
                WebViewHost(webView: web)
                VStack(spacing: 8) {
                    Text(filler.status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button {
                        if let me = model.selectedPerson { model.requireProfile { Task { await filler.fill(person: model.formPerson(me)) } } }
                    } label: { Label("Fill in my details", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(filler.busy).accessibilityIdentifier("link-fill")
                }.padding()
            } else if !filler.status.isEmpty {
                Text(filler.status).font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("Finish from an email")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !startLink.isEmpty, text.isEmpty {
                text = startLink
                if let url = LinkFiller.normalized(startLink) {
                    Task {
                        await filler.open(url)
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("-auto-fill"), let me = model.selectedPerson { await filler.fill(person: model.formPerson(me)) }
                        #endif
                    }
                }
            }
        }
        .onDisappear { filler.close() }
    }
}
