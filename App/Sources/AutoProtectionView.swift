import SwiftUI
import OptOutKitCore

/// What automatic protection does, in plain words. Shown at first use and in Settings, before anything is switched on.
struct AutoExplainer: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let n = model.fullPassSize
        VStack(alignment: .leading, spacing: 8) {
            Label(Loc.f("First, it tries about %lld sites: every site where we found the opt-out form and it can be filled in and sent without you. It fills in only what the form asks for (like name, email and city) and sends what it can. If a recent look found you are not listed on a site, it sends nothing there.", n), systemImage: "paperplane")
            Label("Every 3 months, it sends again to the sites that went through, because brokers add people back, and tries again the ones that did not.", systemImage: "arrow.clockwise")
            Label(Loc.f("Every 6 months, it re-tests all %lld sites from the start, because forms and checks change.", n), systemImage: "checklist")
            Label("On any pass, a site that does not go through is never marked done. It moves to your semi-automated queue, with the reason, and you finish it in the app.", systemImage: "arrow.uturn.forward")
            Label("It never solves a CAPTCHA, never makes an account or pays, and leaves anything that needs a login, ID, a phone call or a certification to you. Some sites email you a link to confirm; that click is yours.", systemImage: "hand.raised")
            Label("It runs when the app is open and, when iOS allows, in the background. The first pass takes a while and carries on where it stopped. You can turn it off any time.", systemImage: "switch.2")
        }
        .font(.footnote)
    }
}

/// The two switches. Used by the first-run page, the Queue banner and Settings.
struct AutoToggles: View {
    @Binding var scan: Bool
    @Binding var optOut: Bool

    var body: some View {
        Toggle("Send opt-out requests automatically", isOn: $optOut).accessibilityIdentifier("auto-optout-toggle")
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
    @State private var confirmRetest = false
    @State private var search = ""
    /// Which groups are unfolded: none to begin with, the counts say enough.
    @State private var open: Set<ActivityGroup> = []
    @Environment(\.dismiss) private var dismiss
    @State private var activity: [AppModel.ActivityRow] = []
    @State private var runNowCount: Int?
    /// The groups have been worked out once (the counts show a placeholder until then, a moment after the page opens).
    @State private var loaded = false
    /// Stop was tapped: the run starts no more sites and ends when the ones in progress finish.
    @State private var stopping = false

    private var busy: Bool { model.autoBusy == "optout" }

    var body: some View {
        List {
            if let person = model.selectedPerson {
                statusSection(for: person)
                groupSections
                moreSection(for: person)
            }
            if !handles.isEmpty {
                Section("Sites in this run (\(handles.count))") {
                    ForEach(handles, id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
        .navigationTitle("Automatic opt-out")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text("Find a site"))
        .onChange(of: busy) { _, now in if !now { stopping = false } }
        .task(id: refreshKey) {
            // Worked out away from the main thread, so the page opens at once and the app stays quick while a run moves on.
            guard let p = model.selectedPerson else { return }
            let inputs = model.activityInputs(for: p)
            let page = await Task.detached(priority: .userInitiated) { AppModel.activityPage(inputs) }.value
            guard !Task.isCancelled else { return }
            activity = page.rows; runNowCount = page.runNow; loaded = true
        }
        .confirmationDialog("Re-test every site now?", isPresented: $confirmRetest, titleVisibility: .visible) {
            Button("Re-test every site") { model.runFullRetestNow() }
                .accessibilityIdentifier("auto-retest-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This tries every site that can be tried, one after another in the background, and sends a request wherever a form goes through. It can take a long while. Anything that does not go through moves to your semi-automated queue.")
        }
        // Links on this page carry their own destination. A page opened by a closure-style link must not declare a `navigationDestination` of its own:
        // SwiftUI builds the page a second time when a value is pushed, finds the route "declared earlier on the stack", and the push bounces straight back.
    }

    /// The groups are worked out again when a run moves on a site, finishes, or the person changes.
    private var refreshKey: String { "\(model.selectedID.uuidString)-\(model.autoBusy ?? "")-\(model.autoProgress?.done ?? -1)-\(model.autoSettings.lastOptOut?.timeIntervalSince1970 ?? 0)" }

    private var filtered: [AppModel.ActivityRow] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? activity : activity.filter { $0.domain.localizedCaseInsensitiveContains(q) }
    }

    private func title(_ g: ActivityGroup) -> String {
        switch g { case .needsYou: return Loc.t("Moved to semi-automatic"); case .sent: return Loc.t("Sent"); case .notListed: return Loc.t("Not listed"); case .notTried: return Loc.t("Not tried or skipped") }
    }
    private func color(_ g: ActivityGroup) -> Color {
        switch g { case .needsYou: return .blue; case .sent: return .green; case .notListed: return .teal; case .notTried: return .secondary }
    }
    private func icon(_ g: ActivityGroup) -> String {
        switch g { case .needsYou: return "hand.point.up.left.fill"; case .sent: return "checkmark.circle.fill"; case .notListed: return "person.crop.circle.badge.xmark"; case .notTried: return "circle.dashed" }
    }
    private func isOpen(_ g: ActivityGroup) -> Bool { !search.isEmpty || open.contains(g) }
    private func toggle(_ g: ActivityGroup) { withAnimation { if open.contains(g) { open.remove(g) } else { open.insert(g) } } }

    /// Everything at a glance: the four counts (each opens its list), the period, the last and next run, and the two buttons.
    @ViewBuilder private func statusSection(for person: Person) -> some View {
        Section {
            HStack(spacing: 8) {
                ForEach(ActivityGroup.allCases, id: \.self) { g in
                    let n = activity.filter { $0.group == g }.count
                    Button { toggle(g) } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: loaded ? "\(n)" : "–").font(.title2.bold()).foregroundStyle(color(g))
                            Text(g == .notTried ? Loc.t("Not tried") : g == .needsYou ? Loc.t("Semi-automatic") : title(g)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(color(g).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("activity-count-\(g.rawValue)")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if busy {
                    if let p = model.autoProgress {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        Text("Working in the background: \(p.done) of \(p.total) sites. You can leave this screen.").font(.caption).accessibilityIdentifier("auto-working")
                        if model.autoCarriedOn {
                            Text("It carried on after a pause, with only the sites it had not done; nothing is sent twice.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("auto-carried-on")
                        }
                    } else {
                        ProgressView().accessibilityIdentifier("auto-working")
                    }
                }
                if let started = model.autoSettings.runStarted {
                    // The groups above are this run's only: a new run starts them afresh. Every run together is "Every site, all runs" below.
                    Text(Loc.f("This run started %@", Loc.date(started))).accessibilityIdentifier("run-started")
                }
                if let period = model.runPeriod() {
                    Text(Loc.f("This period: %@ to %@", Loc.date(period.start), Loc.date(period.end.addingTimeInterval(-1))))
                        .accessibilityIdentifier("period-summary")
                }
                if let last = model.autoSettings.lastOptOut {
                    // A run recorded before the counts were kept has none: just its date, not "sent 0 of 0".
                    Group {
                        if let tried = model.autoSettings.lastAttempted, tried > 0 {
                            Text(Loc.f("Last run %@: sent %lld of %lld", Loc.date(last), model.autoSettings.lastSent ?? 0, tried))
                        } else {
                            Text(Loc.f("Last run %@", Loc.date(last)))
                        }
                    }
                    .accessibilityIdentifier("auto-summary")
                } else if !busy {
                    Text("Nothing has run yet for \(person.displayName).")
                }
                if let next = model.autoSettings.nextOptOutDate() {
                    Group {
                        if model.autoSettings.kindOfRun(on: next) == .full { Text(Loc.f("Next run %@: a full re-test of every site", Loc.date(next))) }
                        else { Text(Loc.f("Next run %@: sends again to the sites that went through and tries again the ones that did not", Loc.date(next))) }
                    }
                    .accessibilityIdentifier("auto-next-run")
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { model.runAutomaticNow() } label: {
                    buttonLabel(busy ? Loc.t("Working…") : Loc.t("Run now"), icon: "bolt.fill")
                }
                .buttonStyle(.borderedProminent).disabled(busy)
                .accessibilityIdentifier("auto-run-now")
                if busy {
                    // While it works, the second button stops it (after the sites in progress, which have a time limit).
                    Button(role: .destructive) { stopping = true; model.stopAutoOptOut() } label: {
                        buttonLabel(stopping ? Loc.t("Stopping…") : Loc.t("Stop"), icon: "stop.fill")
                    }
                    .buttonStyle(.bordered).disabled(stopping)
                    .accessibilityIdentifier("auto-stop")
                } else {
                    Button { confirmRetest = true } label: {
                        buttonLabel(Loc.t("Re-test all"), icon: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("auto-retest-all")
                }
            }
            .controlSize(.regular)
            if !busy, model.runStoppedByPerson {
                Text(Loc.t("Stopped. Nothing runs by itself until you press Run now, which carries on with the sites left."))
                    .font(.caption.bold()).foregroundStyle(.orange).accessibilityIdentifier("auto-stopped")
            }
            if !busy, let n = runNowCount {
                Text(n == 0 ? Loc.t("Nothing is left for Run now this period: what went through is done, and what did not is in your semi-automated queue. Re-test all tries every site again.")
                            : Loc.f("Run now tries the %lld sites still to do this period. Re-test all tries every site again.", n))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("auto-run-now-scope")
            }
        } header: { Text(person.displayName) }
    }

    /// One section per group, folded until its header or count is tapped (all open while searching). A site that needs you is in the semi-automated queue.
    @ViewBuilder private var groupSections: some View {
        ForEach(ActivityGroup.allCases, id: \.self) { g in
            let items = filtered.filter { $0.group == g }
            if !items.isEmpty {
                Section {
                    if isOpen(g) {
                        ForEach(items) { r in
                            if let entry = model.sites[id: r.id] {
                                NavigationLink { DirectoryInfoView(entry: entry) } label: { activityRow(r) }.accessibilityIdentifier("period-site-\(r.domain)")
                            } else { activityRow(r) }
                        }
                    }
                } header: {
                    Button { toggle(g) } label: {
                        HStack {
                            Label(title(g), systemImage: icon(g)).foregroundStyle(color(g))
                            Text(verbatim: "\(items.count)").foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: isOpen(g) ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                        }
                        .font(.subheadline.bold()).textCase(nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("activity-group-\(g.rawValue)")
                } footer: {
                    if g == .needsYou {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nothing to do on this page. These sites need a person for one step, usually a check, so they are in your semi-automated queue: we fill in each form, you clear the check and send.")
                            Button { dismiss(); model.requestedTab = 0 } label: { Label("Go to the semi-automated queue", systemImage: "arrow.right.circle") }
                                .font(.footnote.bold()).accessibilityIdentifier("activity-open-semi")
                        }
                    }
                }
            }
        }
        if !search.isEmpty && filtered.isEmpty {
            Section { Text("No site matches.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    /// Every run combined (each site's page has its screenshot), and the earlier periods, folded away.
    @ViewBuilder private func moreSection(for person: Person) -> some View {
        let history = model.periodHistory(for: person)
        if model.autoSettings.lastAttempted != nil || model.autoSettings.runStarted != nil || history.count > 1 {
            Section {
                if model.autoSettings.lastAttempted != nil || model.autoSettings.runStarted != nil {
                    NavigationLink { AllRunsView(person: person) } label: {
                        Label("Every site, all runs", systemImage: "square.stack.3d.up")
                    }
                    .accessibilityIdentifier("all-runs")
                    // The run as one file for whoever is helping: built only when the share sheet asks for it, and sent nowhere by the app (RunExport).
                    ShareLink(item: RunExportFile(build: { [model] in await model.runExport(for: person) }), preview: SharePreview(Loc.t("Exnay run export"))) {
                        Label("Export this run, screenshots and all", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("export-run")
                }
                if history.count > 1 {
                    DisclosureGroup("Earlier periods") {
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
            } footer: {
                if model.autoSettings.lastAttempted != nil || model.autoSettings.runStarted != nil {
                    Text("The export is one file with every site's result and screenshot, for whoever is helping you. It holds your details as the sites showed them, and goes only where you share it.")
                }
            }
        }
    }

    /// The two buttons' labels, built the same way so their icon and text line up: centred in equal halves, one line.
    private func buttonLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).imageScale(.medium)
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func activityRow(_ r: AppModel.ActivityRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(r.group)).foregroundStyle(color(r.group))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: r.domain).font(.footnote)
                Text(r.line).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

}

/// Every run there has been, combined: each site the automatic run has dealt with or takes on, grouped by its whole history (sent at least once, tried and never
/// sent, never tried), with how often it was sent or tried. A site opens its page, which has the screenshot of its latest result.
struct AllRunsView: View {
    @EnvironmentObject var model: AppModel
    let person: Person
    @State private var search = ""
    @State private var rows: [AppModel.ActivityRow] = []

    var body: some View {
        let shown = search.isEmpty ? rows : rows.filter { $0.domain.localizedCaseInsensitiveContains(search) }
        List {
            Section {
                HStack(spacing: 8) {
                    ForEach(ActivityGroup.allCases, id: \.self) { g in
                        VStack(spacing: 2) {
                            Text(verbatim: "\(rows.filter { $0.group == g }.count)").font(.title2.bold()).foregroundStyle(color(g))
                            Text(title(g)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(color(g).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("all-runs-count-\(g.rawValue)")
                    }
                }
            } footer: { Text("Every automatic run together, since the first. The automatic opt-out page shows only the current run.") }
            ForEach(ActivityGroup.allCases, id: \.self) { g in
                let items = shown.filter { $0.group == g }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { r in
                            if let entry = model.sites[id: r.id] {
                                NavigationLink { DirectoryInfoView(entry: entry) } label: { row(r) }.accessibilityIdentifier("all-runs-site-\(r.domain)")
                            } else { row(r) }
                        }
                    } header: { Label(title(g), systemImage: icon(g)).foregroundStyle(color(g)).textCase(nil) }
                }
            }
        }
        .navigationTitle("Every site, all runs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text("Find a site"))
        .accessibilityIdentifier("all-runs-page")
        .task { rows = model.allRunsRows(for: person) }
    }

    private func row(_ r: AppModel.ActivityRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(r.domain).font(.subheadline)
            Text(r.line).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func title(_ g: ActivityGroup) -> String {
        switch g { case .needsYou: return Loc.t("Never went through"); case .sent: return Loc.t("Sent"); case .notListed: return Loc.t("Not listed"); case .notTried: return Loc.t("Never tried") }
    }
    private func color(_ g: ActivityGroup) -> Color { switch g { case .needsYou: return .orange; case .sent: return .green; case .notListed: return .teal; case .notTried: return .secondary } }
    private func icon(_ g: ActivityGroup) -> String { switch g { case .needsYou: return "exclamationmark.circle"; case .sent: return "checkmark.circle.fill"; case .notListed: return "person.crop.circle.badge.xmark"; case .notTried: return "circle.dashed" } }
}
