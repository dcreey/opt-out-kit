import SwiftUI
import OptOutKitCore

/// What automatic protection does, in plain words. Shown at first use and in Settings, before anything is switched on.
struct AutoExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Every month, it sends opt-out requests. For each site where we found the opt-out form, it fills that form in with only what it asks for (like name, email and city) and sends it. If a recent look found you are not listed there, it sends nothing.", systemImage: "paperplane")
            Label("It never solves a CAPTCHA, never makes an account or pays, and leaves anything that needs a login, ID, a phone call or a certification to you. Some sites email you a link to confirm; that click is yours.", systemImage: "hand.raised")
            Label("Most sites guard their forms with human checks, so expect many to need you. The app tells you which.", systemImage: "info.circle")
            Label("It runs when the app is open and, when iOS allows, in the background. You can turn it off any time.", systemImage: "switch.2")
        }
        .font(.footnote)
    }
}

/// The two switches. Used by the first-run page, the Queue banner and Settings.
struct AutoToggles: View {
    @Binding var scan: Bool
    @Binding var optOut: Bool

    var body: some View {
        Toggle("Send opt-out requests every month", isOn: $optOut).accessibilityIdentifier("auto-optout-toggle")
    }
}

struct AutoProtectionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scan = true
    @State private var optOut = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AutoExplainer()
                }
                Section {
                    AutoToggles(scan: $scan, optOut: $optOut)
                }
                Section {
                    Button("Turn on") { model.setAuto(scan: false, optOut: optOut); dismiss() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("auto-turn-on")
                    Button("Not now") { model.setAuto(scan: false, optOut: false); dismiss() }
                        .accessibilityIdentifier("auto-not-now")
                } footer: {
                    Text("Minors and public figures are never searched (opt-out requests still go out for them).")
                }
            }
            .navigationTitle("Automatic protection")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The automatic opt-out: one button, working in the background. It only asks the person about the sites that did not go through,
/// and those move to semi-automated or guided.
struct AutoActivityView: View {
    @EnvironmentObject var model: AppModel
    /// The sites a plan task says this run handles, listed at the bottom when it is opened from the plan.
    var handles: [String] = []

    private var rows: [AppModel.AutoOptOutRow] { model.selectedPerson.flatMap { model.optOutRun[$0.id] } ?? [] }
    private var busy: Bool { model.autoBusy == "optout" }

    private func isSent(_ r: AppModel.AutoOptOutRow) -> Bool { if case .submitted = r.result { return true } else { return false } }
    /// The ones the person has to do something about.
    private func needsPerson(_ r: AppModel.AutoOptOutRow) -> Bool {
        switch r.result { case .challenged, .needsYou, .needsData, .rejected, .failed: return true; default: return false }
    }

    var body: some View {
        List {
            if let person = model.selectedPerson {
                Section {
                    if busy {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Working in the background", systemImage: "hourglass").font(.headline)
                            if let p = model.autoProgress {
                                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                                Text("\(p.done) of \(p.total) sites. You can leave this screen.").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                            }
                        }
                        .accessibilityIdentifier("auto-working")
                    }
                    Button { model.runAutomaticNow() } label: {
                        Label(busy ? Loc.t("Working…") : Loc.t("Run now"), systemImage: "bolt.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(busy)
                    .accessibilityIdentifier("auto-run-now")
                    if let last = model.autoSettings.lastOptOut {
                        Text("Last run: \(Loc.date(last, time: true))").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let next = model.autoSettings.nextOptOutDate() {
                        Text("Next monthly run: \(Loc.date(next))").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("auto-next-run")
                    }
                } header: { Text(person.displayName) } footer: {
                    Text("It fills in and sends each form in the background, with no website opened. You are only asked about a site if it does not go through, and that site then moves to semi-automated or guided.")
                }
                periodSections(for: person)
                if model.autoSettings.lastAttempted != nil {
                    Section {
                        NavigationLink { RunReviewView(person: person) } label: {
                            Label("Review the last run and its screenshots", systemImage: "photo.on.rectangle.angled")
                        }
                        .accessibilityIdentifier("review-last-run")
                    } footer: { Text("After each site is sent we keep a screenshot of the page it showed, so you can confirm what happened.") }
                }
                if !rows.isEmpty {
                    let sent = rows.filter(isSent).count
                    let attention = rows.filter(needsPerson)
                    Section {
                        Text("Sent \(sent) of \(rows.count) sites. \(attention.count) need you.").font(.headline).accessibilityIdentifier("auto-summary")
                    }
                    if !attention.isEmpty {
                        Section("Needs you (\(attention.count))") {
                            ForEach(attention) { r in
                                if let entry = model.directory.first(where: { $0.id == r.id }) {
                                    NavigationLink { DirectoryInfoView(entry: entry) } label: { attentionRow(r) }
                                } else { attentionRow(r) }
                            }
                        }
                    }
                } else if !busy {
                    Section { Text("Nothing has run yet for \(person.displayName).").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if !handles.isEmpty {
                Section("Sites in this run (\(handles.count))") {
                    ForEach(handles, id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
        .navigationTitle("Automatic opt-out")
        // Links on this page carry their own destination. A page opened by a closure-style link must not declare a `navigationDestination` of its own:
        // SwiftUI builds the page a second time when a value is pushed, finds the route "declared earlier on the stack", and the push bounces straight back.
    }

    /// This period's tally, the checklist of every automatic site (what ran and what did not), and the earlier periods.
    @ViewBuilder private func periodSections(for person: Person) -> some View {
        let history = model.periodHistory(for: person)
        if let now = history.first {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Loc.f("%lld of %lld sites handled this period", now.handled, now.total)).font(.headline).accessibilityIdentifier("period-summary")
                    ProgressView(value: Double(now.handled), total: Double(max(now.total, 1))).tint(now.complete ? .green : .accentColor)
                    Text("\(Loc.date(now.period.start)) to \(Loc.date(now.period.end.addingTimeInterval(-1)))").font(.caption).foregroundStyle(.secondary)
                    if now.complete { Label("Every site went through this period.", systemImage: "checkmark.seal.fill").font(.footnote).foregroundStyle(.green) }
                    else { Text(Loc.f("%lld left. A run only does the sites not handled yet in this period.", now.total - now.handled)).font(.footnote).foregroundStyle(.secondary) }
                }
            } header: { Text("This period") }
            let rows = model.periodRows(for: person)
            let todo = rows.filter { !$0.handled }, done = rows.filter(\.handled)
            Section {
                ForEach(todo + done) { r in
                    if let entry = model.directory.first(where: { $0.id == r.id }) { NavigationLink { DirectoryInfoView(entry: entry) } label: { periodRow(r) }.accessibilityIdentifier("period-site-\(r.domain)") } else { periodRow(r) }
                }
            } header: { Text("Each site") } footer: { Text("A check mark means the request went through this period.") }
            if history.count > 1 {
                Section("Earlier periods") {
                    ForEach(Array(history.dropFirst().enumerated()), id: \.offset) { _, t in
                        HStack {
                            Image(systemName: t.complete ? "checkmark.circle.fill" : "circle.lefthalf.filled").foregroundStyle(t.complete ? .green : .orange)
                            Text("\(Loc.date(t.period.start)) to \(Loc.date(t.period.end.addingTimeInterval(-1)))").font(.footnote)
                            Spacer()
                            Text(Loc.f("%lld of %lld", t.handled, t.total)).font(.footnote.bold())
                        }
                    }
                }
            }
        }
    }

    private func periodRow(_ r: AppModel.PeriodSiteRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.handled ? "checkmark.circle.fill" : (r.note != nil ? "exclamationmark.circle.fill" : "circle"))
                .foregroundStyle(r.handled ? Color.green : (r.note != nil ? Color.orange : Color.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.domain).font(.footnote).foregroundStyle(r.handled ? Color.secondary : Color.primary)
                if let on = r.handledOn { Text(Loc.f("Sent %@", Loc.date(on))).font(.caption2).foregroundStyle(.secondary) }
                else if let note = r.note { Text(note).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                else { Text("Not sent yet").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private func attentionRow(_ r: AppModel.AutoOptOutRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(r.domain)
            Text(r.result.label).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}
