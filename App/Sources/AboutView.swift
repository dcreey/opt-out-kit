import SwiftUI

struct AboutView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Replay the walkthrough", systemImage: "play.circle") { model.showWalkthrough() }
                        .accessibilityIdentifier("show-walkthrough")
                }
                Section("How it works") {
                    Text("Pick a site, follow its step cards in your own browser, and mark each step done. You do any CAPTCHA, phone or ID step yourself. The app never submits anything for you.")
                    Text("Brokers re-list people, so check back on opted-out sites.")
                }
                Section("Privacy") {
                    Text("Your information never leaves this phone, except to the sites you opt out of. There is no Opt-Out Kit server, no account, no analytics and no tracking.")
                    Text("What you enter is stored encrypted on this phone. If you lose your phone without a backup, it is gone. A normal iPhone backup carries it.")
                }
                Section("Open source") {
                    Text("Anyone can audit exactly what this app does.")
                    Link("View the code on GitHub", destination: AppInfo.repoURL)
                    Text("The repository is private until the pre-release checks finish.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Good to know") {
                    Text("Opt-Out Kit is not affiliated with any data broker and is not legal advice. Broker pages change often, so a step may need updating.")
                }
            }
            .accessibilityIdentifier("about-list")
            .navigationTitle("About")
        }
    }
}
