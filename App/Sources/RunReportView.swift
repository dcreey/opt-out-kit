import SwiftUI
import OptOutKitCore

/// What an opt-out run did, in the person's terms: how many went through and which sites need them.
struct RunReport: Identifiable, Equatable {
    let id = UUID()
    let person: String
    let rows: [AppModel.AutoOptOutRow]
    var personID: UUID = UUID()

    var sent: Int { rows.filter { if case .submitted = $0.result { return true } else { return false } }.count }
    /// Sites that did not go through and now wait for the person.
    var needYou: [AppModel.AutoOptOutRow] {
        rows.filter { switch $0.result { case .challenged, .needsYou, .needsData, .rejected, .failed: return true; default: return false } }
    }
    /// Sites the run really tried: the ones that were sent plus the ones that did not go through.
    var attempted: Int { sent + needYou.count }
    var allSucceeded: Bool { attempted > 0 && needYou.isEmpty }
}

/// Shown when a run finishes.
struct RunReportSheet: View {
    let report: RunReport
    let done: () -> Void

    @EnvironmentObject var model: AppModel
    @State private var explainEmail = false

    var body: some View {
        NavigationStack { content.navigationBarHidden(true) }
            .onAppear {
                // The first run that leaves a request waiting on an email explains why, and how the Email links tab finishes it.
                if model.shouldExplainEmailLinks, report.rows.contains(where: { if case .submitted(true) = $0.result { return true } else { return false } }) {
                    model.markEmailLinksExplained(); explainEmail = true
                }
            }
            .sheet(isPresented: $explainEmail) { EmailCheckExplainer(openTab: { explainEmail = false; done(); model.requestedTab = 2 }) { explainEmail = false } }
            .presentationDetents([.medium, .large])
    }

    private var content: some View {
        VStack(spacing: 16) {
            Image(systemName: report.allSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 52)).foregroundStyle(report.allSucceeded ? .green : .orange).padding(.top, 24)
            Text(report.allSucceeded ? Loc.f("All %lld sites went through", report.sent)
                                     : Loc.f("%lld of %lld sites went through", report.sent, report.attempted))
                .font(.title2.bold()).multilineTextAlignment(.center).accessibilityIdentifier("run-report-title")
            if let now = model.periodHistory(for: model.people.first(where: { $0.id == report.personID }) ?? Person(displayName: "")).first {
                Text(Loc.f("%lld of %lld sites handled this period", now.handled, now.total)).font(.subheadline.bold()).foregroundStyle(.secondary).accessibilityIdentifier("run-report-period")
            }
            if report.allSucceeded {
                Text("Nothing more to do for these. Some sites email a link to confirm; that tap is yours.").font(.callout).multilineTextAlignment(.center)
            } else {
                Text("\(report.needYou.count) need you. They moved to your queue as semi-automated or guided tasks.").font(.callout).multilineTextAlignment(.center)
                List(report.needYou) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.domain).font(.headline)
                        Text(r.result.label).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listStyle(.plain)
            }
            if let person = model.people.first(where: { $0.id == report.personID }) {
                NavigationLink { RunReviewView(person: person) } label: {
                    Label("Review every site and its screenshot", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).accessibilityIdentifier("run-report-review")
            }
            Spacer(minLength: 0)
            Button("Done", action: done).buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("run-report-done").padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }
}

/// The last run's result on the home screen, for when the app was closed while it ran.
struct LastRunRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.autoSettings
        if let attempted = s.lastAttempted, attempted > 0, let sent = s.lastSent, let date = s.lastOptOut {
            let needYou = s.lastNeedYou ?? 0
            NavigationLink(value: "auto-activity") {
                HStack(spacing: 10) {
                    Image(systemName: needYou == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(needYou == 0 ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(needYou == 0 ? Loc.f("Last run: all %lld sites went through", sent) : Loc.f("Last run: %lld of %lld went through, %lld need you", sent, attempted, needYou))
                            .font(.subheadline.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(Loc.date(date, time: true)).font(.caption).foregroundStyle(.secondary)
                        if let person = model.selectedPerson, let now = model.periodHistory(for: person).first {
                            Text(Loc.f("This period: %lld of %lld sites handled", now.handled, now.total)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("last-run")
        }
    }
}
