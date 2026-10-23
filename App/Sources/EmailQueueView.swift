import SwiftUI
import MessageUI
import OptOutKitCore

/// The mail sheet, prefilled. The person reads it and taps Send; nothing is sent without that tap.
struct MailComposer: UIViewControllerRepresentable {
    let to: String, subject: String, body: String
    let finished: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([to]); vc.setSubject(subject); vc.setMessageBody(body, isHTML: false)
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

/// Every site that takes opt-outs by email, as a short list of messages (one per address). Open a message, read it, tap Send.
struct EmailQueueView: View {
    @EnvironmentObject var model: AppModel
    let domains: [String]
    @State private var composing: EmailBatch?

    private var person: Person? { model.selectedPerson }
    private var batches: [EmailBatch] {
        let set = Set(domains)
        return EmailBatch.build(entries: model.directory.filter { set.contains($0.domain) })
    }
    private func done(_ b: EmailBatch) -> Bool { b.entryIDs.allSatisfy { model.wasEmailed($0) } }

    var body: some View {
        let list = batches
        let pending = list.filter { !done($0) }
        List {
            Section {
                Text("\(list.count) messages cover \(domains.count) sites. Each message names every site its address handles. Open one, read it, and tap Send in your mail app.")
                    .font(.footnote)
                if let next = pending.first {
                    Button { open(next) } label: {
                        Label("Open the next message (\(pending.count) left)", systemImage: "envelope.open").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("email-next")
                } else {
                    Label("All messages sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if !MFMailComposeViewController.canSendMail() {
                    Label("Mail is not set up on this device. Each message opens in your default mail app instead.", systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section("Messages") {
                ForEach(list) { b in
                    Button { open(b) } label: {
                        HStack {
                            Image(systemName: done(b) ? "checkmark.circle.fill" : "circle").foregroundStyle(done(b) ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.address).font(.headline)
                                Text(b.domains.count == 1 ? b.domains[0] : "\(b.domains.count) sites: \(b.domains.prefix(3).joined(separator: ", "))…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("email-\(b.address)")
                }
            }
        }
        .navigationTitle("Opt-out emails")
        .sheet(item: $composing) { b in
            MailComposer(to: b.address, subject: b.subject, body: model.emailBody(for: b)) { result in
                if result == .sent { model.markEmailed(b) }
                composing = nil
            }
            .ignoresSafeArea()
        }
    }

    private func open(_ b: EmailBatch) {
        model.requireProfile {
            if MFMailComposeViewController.canSendMail() { composing = b }
            else if let url = model.mailtoURL(for: b) { UIApplication.shared.open(url) }
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
