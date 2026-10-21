import SwiftUI
import OptOutKitCore

private struct Page: Identifiable {
    let id: Int
    let symbol: String
    let title: String
    let body: String
    var bullets: [String] = []
}

/// First-install walkthrough, also reachable from About. Explains what the app does and how to use it.
struct OnboardingView: View {
    /// Called with the person's answers to the automatic-protection page (daily scan, weekly opt-out).
    var onDecide: ((Bool, Bool) -> Void)?
    let onFinish: () -> Void
    @State private var index = 0
    @State private var autoScan = true
    @State private var autoOptOut = true

    private let pages: [Page] = [
        Page(id: 0, symbol: "person.crop.circle.badge.minus", title: "Take your data back",
             body: "Data brokers sell your name, address and relatives. Opt-Out Kit walks you through removing you, and anyone you add, from them.",
             bullets: ["Pick a site from your queue", "Follow the steps in your own browser", "Come back later to check you stayed removed"]),
        Page(id: 1, symbol: "lock.shield", title: "Your data stays on this phone",
             body: "There is no Opt-Out Kit server, no account and no tracking. What you enter is encrypted on this phone. The app only talks to the broker sites themselves, to opt you out.",
             bullets: ["Open source: anyone can audit the code", "Lost phone with no backup means lost data; a normal iPhone backup carries it", "Each site sees only the details its form needs"]),
        Page(id: 2, symbol: "person.2", title: "Set up people once",
             body: "Tap Profile to add every name you have been listed under, plus current and past addresses and your emails. Add family members as extra people with the account switcher.",
             bullets: ["Nicknames and old names find more listings", "Each person has their own progress", "Family only. Add someone who asked you to, or a child you are the parent or guardian of"]),
        Page(id: 3, symbol: "list.number", title: "Work through a site",
             body: "Open a site to see its step cards. Tap Open in Safari, copy your details, do the step, then tap Mark done. Later steps unlock as you go.",
             bullets: ["You solve any CAPTCHA, phone code or ID step yourself", "The app never submits anything for you", "Some sites clear several brands at once"]),
        Page(id: 4, symbol: "checkmark.seal", title: "Track every site",
             body: "The Sites tab lists every broker with its status for each person: not started, in progress, partial or opted out. Brokers re-list people, so plan to re-check; reminders are coming.",
             bullets: ["Search sites by name or web address", "Tap a site to see what it will receive", "Partial means some of your people are done"]),
    ]

    var body: some View {
        VStack {
            TabView(selection: $index) {
                ForEach(pages) { page in
                    ScrollView {
                        VStack(spacing: 18) {
                            Image(systemName: page.symbol).font(.system(size: 64)).foregroundStyle(.tint).padding(.top, 40)
                            Text(page.title).font(.title.bold()).multilineTextAlignment(.center)
                            Text(page.body).multilineTextAlignment(.center)
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(page.bullets, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.callout) }
                            }
                            .padding(.top, 4)
                        }
                        .padding(.horizontal, 28)
                    }
                    .tag(page.id)
                }
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "bolt.shield").font(.system(size: 64)).foregroundStyle(.tint).padding(.top, 40)
                        Text("Automatic protection").font(.title.bold())
                        AutoExplainer()
                        VStack { AutoToggles(scan: $autoScan, optOut: $autoOptOut) }
                    }
                    .padding(.horizontal, 28)
                }
                .tag(pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack {
                Button("Skip", action: onFinish).accessibilityIdentifier("onboarding-skip")
                Spacer()
                if index < pages.count {
                    Button("Next") { withAnimation { index += 1 } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding-next")
                } else {
                    Button((autoScan || autoOptOut) ? "Turn on and start" : "Start") {
                        onDecide?(autoScan, autoOptOut)
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding-done")
                }
            }
            .padding()
        }
    }
}

/// Shown on an update that carries new announcements. Never shown on a fresh install.
struct WhatsNewView: View {
    let items: [Announcement]
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            List(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline)
                    Text(item.body).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("What's new")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onFinish) } }
        }
    }
}
