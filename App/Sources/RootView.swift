import SwiftUI
import OptOutKitCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            BrokerListView().tabItem { Label("Queue", systemImage: "list.bullet") }.tag(0)
            SitesView().tabItem { Label("Sites", systemImage: "magnifyingglass") }.tag(1)
            AboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(2)
        }
        .sheet(isPresented: $model.showProfileGate) { ProfileGateView() }
        .onChange(of: tab) { _, _ in Keyboard.hide() }
        .keyboardDone()
        .fullScreenCover(isPresented: Binding(
            get: { model.pending == .walkthrough },
            set: { _ in })) {
            OnboardingView(onDecide: { scan, optOut in model.setAuto(scan: scan, optOut: optOut) }) { model.finishAnnouncements() }.keyboardDone()
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
