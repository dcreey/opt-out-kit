import SwiftUI
import OptOutKitCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var showDemoReview = false
    @State private var debugLink: String?
    #if DEBUG
    @State private var debugSemi: DebugSemi?
    @State private var showSiteReview = false
    #endif

    var body: some View {
        TabView(selection: $tab) {
            BrokerListView().tabItem { Label("Queue", systemImage: "list.bullet") }.tag(0)
            SitesView().tabItem { Label("Sites", systemImage: "magnifyingglass") }.tag(1)
            LinkFillerView(startLink: debugLink ?? "").tabItem { Label("Email links", systemImage: "envelope.open") }.badge(model.pendingFollowUps.count).tag(2)
            AboutView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
        .onChange(of: model.incomingLink) { _, link in if link != nil { tab = 2 } }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            // Simulator work: `-real-run -only-domains a.com,b.com` SENDS the requests for the owner's profile on this device and records what each site showed.
            if args.contains("-real-run"), let me = model.people.first(where: { $0.relationship == .me }) {
                await model.runAutoOptOut(for: me, dryRun: false, automaticOnly: false)
            }
            if args.contains("-real-send"), let i = args.firstIndex(of: "-real-send-domains"), args.indices.contains(i + 1) {
                await FormAudit.realSend(domains: args[i + 1].split(separator: ",").map(String.init), model: model)
            }
            if let i = args.firstIndex(of: "-dry-live-domains"), args.indices.contains(i + 1) {
                await FormAudit.dryLive(domains: args[i + 1].split(separator: ",").map(String.init), model: model)
            }
            if let i = args.firstIndex(of: "-audit-range"), args.indices.contains(i + 1) {
                let parts = args[i + 1].split(separator: "-").compactMap { Int($0) }
                if parts.count == 2 { await FormAudit.run(domains: FormAudit.range(from: parts[0], to: parts[1], model: model), model: model) }
            }
            if args.contains("-dump-semi-order"), let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                // Simulator work: the semi-automatic sites in queue order, as Documents/semi-order.json.
                try? JSONSerialization.data(withJSONObject: FormAudit.semi(model: model)).write(to: docs.appendingPathComponent("semi-order.json"))
            }
            if args.contains("-audit-semi") { await FormAudit.run(domains: FormAudit.semi(model: model), model: model) }
            if args.contains("-audit-all") {
                await FormAudit.run(domains: FormAudit.all(model: model), model: model)
            } else if let i = args.firstIndex(of: "-audit-first-per-kind"), args.indices.contains(i + 1), let n = Int(args[i + 1]) {
                await FormAudit.run(domains: FormAudit.firstPerKind(n, model: model), model: model)
            } else if let i = args.firstIndex(of: "-audit-domains"), args.indices.contains(i + 1) {
                await FormAudit.run(domains: args[i + 1].split(separator: ",").map(String.init), model: model)
            }
            // Simulator work: `-semi-domains a.com,b.com` opens the Solve-and-send screen on those sites for the owner's profile.
            if let i = args.firstIndex(of: "-semi-domains"), args.indices.contains(i + 1), let me = model.people.first(where: { args.contains("-uitest-seed-family") ? $0.relationship == .parent : $0.relationship == .me }) {
                let items = model.verifyItems(domains: args[i + 1].split(separator: ",").map(String.init), for: me)
                // Results are saved as the Tap to verify screen saves them, so a test can look at a site's state afterwards.
                debugSemi = DebugSemi(runner: AssistedRunner(items: items, driver: model.makeAssistedDriver()) { [model] entry, result in model.recordAssisted(entry, result, for: me) })
            }
            if args.contains("-site-review") { showSiteReview = true }          // the temporary admin screen: mark each site's opt-out page
            if let i = args.firstIndex(of: "-open-link-filler"), args.indices.contains(i + 1) { debugLink = args[i + 1]; tab = 2 }
            if args.contains("-uitest-demo-run") { await model.runDemoOptOut() }
            if args.contains("-uitest-demo-review") { await model.runDemoOptOut(); model.runReport = nil; showDemoReview = true }
        }
        .fullScreenCover(item: $debugSemi) { box in AssistedOptOutView(runner: box.runner) }
        .fullScreenCover(isPresented: $showSiteReview) { SiteReviewView(entries: model.directory) }
        .sheet(isPresented: $showDemoReview) {
            if let me = model.people.first(where: { $0.relationship == .me }) { NavigationStack { RunReviewView(person: me) } }
        }
        #endif
        .task { try? await Task.sleep(nanoseconds: 700_000_000); model.resumeSetupIfNeeded() }          // the first run picks up where a crash or a close left it
        .onChange(of: model.requestedTab) { _, t in if let t { tab = t; model.requestedTab = nil } }
        .sheet(isPresented: $model.showProfileGate) { ProfileGateView() }
        .sheet(item: $model.runReport) { report in RunReportSheet(report: report) { model.runReport = nil } }
        .fullScreenCover(isPresented: Binding(
            get: { model.pending == .walkthrough },
            set: { _ in })) {
            OnboardingView(onDecide: { scan, optOut in model.setAuto(scan: scan, optOut: optOut) }) { model.finishAnnouncements() }
        }
        .sheet(isPresented: Binding(
            get: { if case .whatsNew = model.pending { return true } else { return false } },
            set: { if !$0 { model.finishAnnouncements() } })) {
            if case .whatsNew(let items) = model.pending {
                WhatsNewView(items: items) { model.finishAnnouncements() }
            }
        }
        .environment(\.locale, model.locale)          // SwiftUI literals follow the chosen language
        .id(model.language)                            // and words built in code are rebuilt when it changes
    }
}

#if DEBUG
struct DebugSemi: Identifiable { let runner: AssistedRunner; var id: ObjectIdentifier { ObjectIdentifier(runner) } }
#endif
