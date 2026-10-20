import SwiftUI
import OptOutKitCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            BrokerListView().tabItem { Label("Queue", systemImage: "list.bullet") }
            SitesView().tabItem { Label("Sites", systemImage: "magnifyingglass") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.pending == .walkthrough },
            set: { _ in })) {
            OnboardingView { model.finishAnnouncements() }
        }
        .sheet(isPresented: Binding(
            get: { if case .whatsNew = model.pending { return true } else { return false } },
            set: { if !$0 { model.finishAnnouncements() } })) {
            if case .whatsNew(let items) = model.pending {
                WhatsNewView(items: items) { model.finishAnnouncements() }
            }
        }
    }
}
