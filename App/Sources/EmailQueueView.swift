import SwiftUI
import MessageUI
import OptOutKitCore

/// The mail sheet, prefilled. The person reads it and taps Send; nothing is sent without that tap.
struct MailComposer: UIViewControllerRepresentable {
    let to: [String], bcc: [String], subject: String, body: String
    let finished: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients(to); vc.setBccRecipients(bcc); vc.setSubject(subject); vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(finished) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let finished: (MFMailComposeResult) -> Void
        init(_ f: @escaping (MFMailComposeResult) -> Void) { finished = f }
        func mailComposeController(_ c: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            c.dismiss(animated: true) { self.finished(result) }
        }
    }
}

/// Every site that takes opt-outs by email, as one message to all their addresses (Bcc, so none sees another). Open it, read it, tap Send.
struct EmailQueueView: View {
    @EnvironmentObject var model: AppModel
    let domains: [String]
    /// How many addresses go in one message (the default keeps to Gmail's limit; "send to everyone" uses 100).
    var perMessage: Int = EmailBatch.maxRecipients
    @State private var composing: EmailBatch?
    @State private var confirmSent: EmailBatch?

    private var batches: [EmailBatch] {
        let set = Set(domains)
        return EmailBatch.single(entries: model.directory.filter { set.contains($0.domain) }, maxRecipients: perMessage)
    }
    private func done(_ b: EmailBatch) -> Bool { b.entryIDs.allSatisfy { model.wasEmailed($0) } }
    /// The mail apps on this phone we know how to open, besides the system Mail composer.
    private var installedApps: [MailApp] {
        MailApp.allCases.filter { app in
            guard let scheme = app.probeScheme, let url = URL(string: scheme + "://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    var body: some View {
        let list = batches
        List {
            Section {
                Text(list.count == 1
                     ? Loc.f("One message goes to %lld addresses (%lld sites). Every address is in Bcc, so no company sees another. You get a copy. Open it, read it, and tap Send.", list[0].addresses.count, domains.count)
                     : Loc.f("%lld messages go to %lld addresses (%lld sites). Every address is in Bcc, so no company sees another. You get a copy. Open each, read it, and tap Send.", list.count, list.reduce(0) { $0 + $1.addresses.count }, domains.count))
                    .font(.footnote)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, b in
                Section(list.count > 1 ? "Message \(index + 1) of \(list.count)" : "The message") {
                    if done(b) {
                        Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button { open(b, app: .mail) } label: { Label("Open in Mail", systemImage: "envelope.open").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("email-open-mail")
                        ForEach(installedApps, id: \.self) { app in
                            Button { open(b, app: app) } label: { Label("Open in \(app.name)", systemImage: "envelope").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).accessibilityIdentifier("email-open-\(app.rawValue)")
                        }
                        Button { open(b, app: .other) } label: { Label("Use another mail app", systemImage: "ellipsis.circle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).accessibilityIdentifier("email-open-other")
                    }
                    Text("\(b.addresses.count) addresses, \(b.domains.count) sites").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Sites in this message") { ForEach(b.domains, id: \.self) { Text($0).font(.footnote) } }
                }
            }
            if !MFMailComposeViewController.canSendMail() {
                Section { Label("Mail is not set up on this device, so \"Open in Mail\" opens your default mail app.", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Opt-out email")
        .sheet(item: $composing) { b in
            MailComposer(to: [model.formEmail].compactMap { $0 }, bcc: b.addresses, subject: b.subject, body: model.emailBody(for: b)) { result in
                if result == .sent { model.markEmailed(b) }
                composing = nil
            }
            .ignoresSafeArea()
        }
        .alert("Did you send it?", isPresented: Binding(get: { confirmSent != nil }, set: { if !$0 { confirmSent = nil } })) {
            Button("Yes, I sent it") { if let b = confirmSent { model.markEmailed(b) }; confirmSent = nil }
            Button("No", role: .cancel) { confirmSent = nil }
        } message: { Text("The Gmail and default mail apps do not tell us whether you sent the message. Mark it as sent only if you did.") }
    }

    private func open(_ b: EmailBatch, app: MailApp) {
        model.requireProfile {
            if app == .mail, MFMailComposeViewController.canSendMail() { composing = b; return }
            // Every other way of opening a message cannot tell us whether it was sent, so we ask afterwards.
            if let url = model.composeURL(for: b, app: app) { UIApplication.shared.open(url); confirmSent = b }
        }
    }
}

/// The forms that only need a bot check ticked. Each page is loaded and filled in for the person in turn; they tick the box, the app sends it.
struct VerifyQueueView: View {
    @EnvironmentObject var model: AppModel
    let domains: [String]
    @State private var runner: AssistedRunner?

    var body: some View {
        let person = model.selectedPerson
        let items = person.map { model.verifyItems(domains: domains, for: $0) } ?? []
        List {
            Section {
                Text("These \(domains.count) sites are filled in for you. Each shows a \"verify you are human\" box that only a person can tick. The next page loads while you tick the current one, so it is one tap per site.")
                    .font(.footnote)
                Button {
                    model.requireProfile {
                        guard let p = model.selectedPerson else { return }
                        runner = AssistedRunner(items: model.verifyItems(domains: domains, for: p), driver: model.makeAssistedDriver()) { entry, result in
                            model.recordAssisted(entry, result, for: p)
                        }
                    }
                } label: {
                    Label(items.isEmpty ? "Nothing left to verify" : "Start (\(items.count) pages)", systemImage: "hand.tap").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(items.isEmpty && model.isReady(person ?? Person(displayName: "")))
                .accessibilityIdentifier("verify-start")
            }
            Section("Sites") { ForEach(domains, id: \.self) { Text($0).font(.footnote) } }
        }
        .navigationTitle("Tap to verify")
        .fullScreenCover(item: Binding(get: { runner.map(VerifyRunnerBox.init) }, set: { if $0 == nil { runner = nil } })) { box in
            AssistedOptOutView(runner: box.runner)
        }
    }
}

private struct VerifyRunnerBox: Identifiable {
    let runner: AssistedRunner
    var id: ObjectIdentifier { ObjectIdentifier(runner) }
}
