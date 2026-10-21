import SwiftUI
import OptOutKitCore

/// What automatic protection does, in plain words. Shown at first use and in Settings, before anything is switched on.
struct AutoExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Every day, it checks the sites it can for your name.", systemImage: "dot.radiowaves.left.and.right")
            Label("Every week, it sends opt-out requests. For each site where we found the opt-out form, it fills that form in with only what it asks for (like name, email and city) and sends it. If a recent look found you are not listed there, it sends nothing.", systemImage: "paperplane")
            Label("It never solves a CAPTCHA, never makes an account or pays, and leaves anything that needs a login, ID, a phone call or a certification to you. Some sites email you a link to confirm; that click is yours.", systemImage: "hand.raised")
            Label("Most sites guard their forms with bot checks, so expect many to need you. The app tells you which.", systemImage: "info.circle")
            Label("It runs when the app is open and, when iOS allows, in the background. You can turn either off any time.", systemImage: "switch.2")
        }
        .font(.footnote)
    }
}

/// The two switches. Used by the first-run page, the Queue banner and Settings.
struct AutoToggles: View {
    @Binding var scan: Bool
    @Binding var optOut: Bool

    var body: some View {
        Toggle("Check for my listings every day", isOn: $scan).accessibilityIdentifier("auto-scan-toggle")
        Toggle("Send opt-out requests every week", isOn: $optOut).accessibilityIdentifier("auto-optout-toggle")
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
                    Button("Turn on") { model.setAuto(scan: scan, optOut: optOut); dismiss() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("auto-turn-on")
                    Button("Not now") { model.setAuto(scan: false, optOut: false); dismiss() }
                        .accessibilityIdentifier("auto-not-now")
                } footer: {
                    Text("Only family members you added are included, and minors and public figures are never searched (opt-out requests still go out for them).")
                }
            }
            .navigationTitle("Automatic protection")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// What the automatic runs did for the selected person.
struct AutoActivityView: View {
    @EnvironmentObject var model: AppModel

    private var rows: [AppModel.AutoOptOutRow] { model.selectedPerson.flatMap { model.optOutRun[$0.id] } ?? [] }

    var body: some View {
        List {
            if let person = model.selectedPerson {
                Section {
                    runLine("Last scan", model.autoSettings.lastScan)
                    runLine("Last opt-out run", model.autoSettings.lastOptOut)
                    if let busy = model.autoBusy { Label(busy == "scan" ? "Scanning…" : "Sending requests…", systemImage: "hourglass") }
                    Button("Preview: fill the forms, send nothing", systemImage: "eye") {
                        Task { await model.runAutoOptOut(for: person, dryRun: true) }
                    }.accessibilityIdentifier("auto-preview")
                    Button("Send opt-out requests now", systemImage: "paperplane.fill") {
                        Task { await model.runAutoOptOut(for: person) }
                    }.accessibilityIdentifier("auto-run-now")
                } header: { Text(person.displayName) }
                if rows.isEmpty {
                    Section { Text("Nothing has run yet for \(person.displayName).").font(.footnote).foregroundStyle(.secondary) }
                } else {
                    summary
                    group("Sent", rows.filter { if case .submitted = $0.result { return true } else { return false } }, tint: .green)
                    group("Stopped by a bot check or terms prompt", rows.filter { if case .challenged = $0.result { return true } else { return false } }, tint: .orange)
                    group("Needs you", rows.filter { if case .needsYou = $0.result { return true } else { return false } }, tint: .orange)
                    group("Add details to your profile", rows.filter { if case .needsData = $0.result { return true } else { return false } }, tint: .blue)
                    group("Ready (preview only)", rows.filter { $0.result == .dryRunReady }, tint: .blue)
                    group("Skipped or sent recently", rows.filter { switch $0.result { case .skippedNotListed, .tooSoon: return true; default: return false } }, tint: .secondary)
                    group("The site refused or showed no confirmation", rows.filter { switch $0.result { case .rejected, .failed: return true; default: return false } }, tint: .red)
                }
            }
        }
        .navigationTitle("Automatic activity")
    }

    private func runLine(_ title: String, _ date: Date?) -> some View {
        HStack { Text(title); Spacer(); Text(date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet").foregroundStyle(.secondary) }
            .font(.footnote)
    }

    private var summary: some View {
        let sent = rows.filter { if case .submitted = $0.result { return true } else { return false } }.count
        let needsYou = rows.filter { switch $0.result { case .needsYou, .challenged, .needsData: return true; default: return false } }.count
        return Section {
            Text("Sent \(sent) of \(rows.count) sites. \(needsYou) need you.").font(.headline).accessibilityIdentifier("auto-summary")
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [AppModel.AutoOptOutRow], tint: Color) -> some View {
        if !items.isEmpty {
            Section("\(title) (\(items.count))") {
                ForEach(items) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.domain)
                        Text(r.result.label).font(.caption).foregroundStyle(tint)
                    }
                }
            }
        }
    }
}
