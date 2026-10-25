import SwiftUI
import OptOutKitCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var showDemoReview = false

    var body: some View {
        TabView(selection: $tab) {
            BrokerListView().tabItem { Label("Queue", systemImage: "list.bullet") }.tag(0)
            SitesView().tabItem { Label("Sites", systemImage: "magnifyingglass") }.tag(1)
            AboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(2)
        }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-audit-all") {
                await FormAudit.run(domains: FormAudit.all(model: model), model: model)
            } else if let i = args.firstIndex(of: "-audit-first-per-kind"), args.indices.contains(i + 1), let n = Int(args[i + 1]) {
                await FormAudit.run(domains: FormAudit.firstPerKind(n, model: model), model: model)
            } else if let i = args.firstIndex(of: "-audit-domains"), args.indices.contains(i + 1) {
                await FormAudit.run(domains: args[i + 1].split(separator: ",").map(String.init), model: model)
            }
            if args.contains("-uitest-demo-run") { await model.runDemoOptOut() }
            if args.contains("-uitest-demo-review") { await model.runDemoOptOut(); model.runReport = nil; showDemoReview = true }
        }
        .sheet(isPresented: $showDemoReview) {
            if let me = model.people.first(where: { $0.relationship == .me }) { NavigationStack { RunReviewView(person: me) } }
        }
        #endif
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
