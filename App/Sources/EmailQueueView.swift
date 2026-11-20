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
    @State private var explainAdID: (batch: EmailBatch, app: MailApp)?

    private var batches: [EmailBatch] {
        let set = Set(domains)
        return EmailBatch.single(entries: model.directory.filter { set.contains($0.domain) }, maxRecipients: perMessage)
    }
    private func done(_ b: EmailBatch) -> Bool { b.entryIDs.allSatisfy { model.wasEmailed($0) } }
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
                        Button { open(b, app: model.mailApp) } label: { Label("Open in \(model.mailApp.name)", systemImage: "envelope.open").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("email-open-mail")
                        Menu {
                            ForEach(model.installedMailApps.filter { $0 != model.mailApp }, id: \.self) { app in
                                Button("Open in \(app.name)") { open(b, app: app) }.accessibilityIdentifier("email-open-\(app.rawValue)")
                            }
                            Button("Use another mail app") { open(b, app: .other) }.accessibilityIdentifier("email-open-other")
                        } label: { Label("Use a different mail app", systemImage: "ellipsis.circle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    Text("\(b.addresses.count) addresses, \(b.domains.count) sites").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Sites in this message") { ForEach(b.domains, id: \.self) { Text($0).font(.footnote) } }
                }
            }
            if model.mailApp == .mail, !MFMailComposeViewController.canSendMail() {
                Section { Label("Mail is not set up on this device, so \"Open in Mail\" opens your default mail app.", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Opt-out email")
        .sheet(item: $composing) { b in
            MailComposer(to: model.recipients(for: b).to, bcc: model.recipients(for: b).bcc, subject: b.subject, body: model.emailBody(for: b)) { result in
                if result == .sent { model.markEmailed(b) }
                composing = nil
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(get: { explainAdID != nil }, set: { if !$0 { explainAdID = nil } })) {
            if let a = explainAdID {
                AdIDExplainer(siteName: a.batch.entryIDs.first.flatMap { model.sites[id: $0] }?.name ?? "This company",
                              onContinue: { explainAdID = nil; Task { await model.loadAdID(for: a.batch); launch(a.batch, app: a.app) } },
                              onSkip: { explainAdID = nil; model.skipAdID(); launch(a.batch, app: a.app) })
            }
        }
        .alert("Did you send it?", isPresented: Binding(get: { confirmSent != nil }, set: { if !$0 { confirmSent = nil } })) {
            Button("Yes, I sent it") { if let b = confirmSent { model.markEmailed(b) }; confirmSent = nil }
            Button("No", role: .cancel) { confirmSent = nil }
        } message: { Text("The Gmail and default mail apps do not tell us whether you sent the message. Mark it as sent only if you did.") }
    }

    private func open(_ b: EmailBatch, app: MailApp) {
        model.requireProfile {
            if model.needsAdIDExplained(for: b) { explainAdID = (b, app); return }
            Task { await model.loadAdID(for: b); launch(b, app: app) }
        }
    }

    private func launch(_ b: EmailBatch, app: MailApp) {
        if app == .mail, MFMailComposeViewController.canSendMail() { composing = b; return }
        // Every other way of opening a message cannot tell us whether it was sent, so we ask afterwards.
        if let url = model.composeURL(for: b, app: app) { UIApplication.shared.open(url); confirmSent = b }
    }
}

/// The forms that only need a human check ticked. Each page is loaded and filled in for the person in turn; they tick the box, the app sends it.
struct VerifyQueueView: View {
    @EnvironmentObject var model: AppModel
    let domains: [String]
    @State private var runner: AssistedRunner?

    /// The sites of this list: the ones still to do first, finished ones (with a check mark) after. Every site opens its page, which shows the
    /// screenshot of what happened for a finished one.
    @ViewBuilder private var siteRows: some View {
        let byDomain = model.sites.byDomain
        let attempts = model.progress.optOutAttempts
        let entries = domains.compactMap { byDomain[$0] }
        let finished = Set(entries.filter { $0.isCurrent(attempts: attempts) }.map(\.id))
        let ordered = entries.filter { !finished.contains($0.id) } + entries.filter { finished.contains($0.id) }
        Section {
            ForEach(ordered, id: \.id) { entry in
                let done = finished.contains(entry.id)
                NavigationLink {
                    DirectoryInfoView(entry: entry)
                } label: {
                    HStack {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.green : Color.secondary)
                        Text(entry.domain).font(.footnote).foregroundStyle(done ? Color.secondary : Color.primary)
                    }
                }
                .accessibilityIdentifier("queue-site-\(entry.domain)")
            }
        } header: { Text("Sites (\(finished.count) of \(entries.count) done)") }
    }

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
            siteRows
            if !model.skippedSites.isEmpty {
                Section {
                    NavigationLink { SkippedSitesView() } label: {
                        Label("Skipped sites (\(model.skippedSites.count))", systemImage: "forward")
                    }.accessibilityIdentifier("skipped-sites-link")
                } footer: { Text("Sites you skip or report as not working wait here for a week, so they never hold up the next batch.") }
            }
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


/// Which mail app opens the emails we prepare. Used in the walkthrough and in About.
struct MailAppPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Open emails in", selection: Binding(get: { model.mailApp }, set: { model.setMailApp($0) })) {
            ForEach(model.installedMailApps, id: \.self) { Text($0.name).tag($0) }
        }
        .pickerStyle(.menu).accessibilityIdentifier("mail-app-picker")
    }
}


/// Sites the person set aside: when each comes back, and a way to bring one back now or skip it for good.
struct SkippedSitesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let sites = model.skippedSites
        List {
            if sites.isEmpty { Section { Text("Nothing is set aside.").font(.footnote).foregroundStyle(.secondary) } }
            ForEach(sites, id: \.entry.id) { row in
                Section {
                    NavigationLink { DirectoryInfoView(entry: row.entry) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.entry.domain).font(.headline)
                            Text(status(row)).font(.caption).foregroundStyle(row.returns == nil && !row.forever ? Color.orange : Color.secondary)
                        }
                    }
                    if !row.forever { Button("Bring back now") { model.bringBack(row.entry.id) }.accessibilityIdentifier("skipped-bring-back-\(row.entry.domain)") }
                    if row.forever { Button("Bring back") { model.bringBack(row.entry.id) } }
                    else {
                        Button("Skip forever", role: .destructive) { model.skipSite(row.entry.id, forever: true) }.accessibilityIdentifier("skipped-forever-\(row.entry.domain)")
                    }
                }
            }
        }
        .navigationTitle("Skipped sites")
        .accessibilityIdentifier("skipped-sites")
    }

    private func status(_ row: (entry: DirectoryEntry, skip: SiteSkip, returns: Date?, forever: Bool)) -> String {
        let why = row.skip.reason == .notWorking ? Loc.t("Marked as not working") : Loc.t("Skipped")
        if row.forever { return Loc.f("%@ · skipped for good", why) }
        if let back = row.returns { return Loc.f("%@ · comes back %@", why, back.formatted(date: .abbreviated, time: .omitted)) }
        return Loc.f("%@ · ready to try again", why)
    }
}


/// Requests that have waited on the site's confirmation email past the usual 45 days: finish them, redo them, or write to the site.
struct FollowUpsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = model.overdueFollowUps
        List {
            if items.isEmpty { Section { Text("Nothing is waiting on an email.").font(.footnote).foregroundStyle(.secondary) } }
            ForEach(items, id: \.entry.id) { item in
                Section {
                    NavigationLink { DirectoryInfoView(entry: item.entry) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.entry.domain).font(.headline)
                            let days = Int(Date().timeIntervalSince(item.since) / 86_400)
                            Text(Loc.f("Sent %@ (%lld days ago). The confirmation email never came.", item.since.formatted(date: .abbreviated, time: .omitted), days)).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Button("I finished it") { model.markFollowUpDone(item.entry.id) }.accessibilityIdentifier("followup-done-\(item.entry.domain)")
                    if let mail = item.entry.contactEmail, let url = DirectoryInfoView.mailto(mail, person: model.selectedPerson, email: model.formEmail, site: item.entry.domain) {
                        Link(destination: url) { Label("Email them about it", systemImage: "envelope") }
                    }
                }
            }
        }
        .navigationTitle("Follow up")
        .accessibilityIdentifier("followups")
    }
}
