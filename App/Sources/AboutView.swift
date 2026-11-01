import SwiftUI
import OptOutKitCore

struct AboutView: View {
    @EnvironmentObject var model: AppModel
    @State private var showApproval = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Replay the walkthrough", systemImage: "play.circle") { model.showWalkthrough() }
                        .accessibilityIdentifier("show-walkthrough")
                }
                Section {
                    MailAppPicker()
                } header: { Text("Email") } footer: { Text("Opt-out emails we prepare open in this app, ready for you to read and send.") }
                AdvertisingIDSection()
                Section("How it works") {
                    Text("Pick a site, follow its step cards in your own browser, and mark each step done. You do any CAPTCHA, phone or ID step yourself. The app never submits anything for you.")
                    Text("Brokers re-list people, so check back on opted-out sites.")
                }
                Section("Privacy") {
                    Text("Your information never leaves this phone, except to the sites you opt out of. There is no Exnay server, no account, no analytics and no tracking.")
                    Text("What you enter is stored encrypted on this phone. If you lose your phone without a backup, it is gone. A normal iPhone backup carries it.")
                }
                Section { NavigationLink { GPCSetupView() } label: { Label(model.gpcSetupDone ? "Global Privacy Control: done" : "Set up Global Privacy Control", systemImage: model.gpcSetupDone ? "checkmark.circle.fill" : "hand.raised.square") }
                    NavigationLink { GlobalPrivacyControlView() } label: { Label("Global Privacy Control", systemImage: "hand.raised.square") }.accessibilityIdentifier("gpc-link") }
                Section {
                    if let j = model.ownerJurisdiction {
                        NavigationLink("Your place: \(j.displayName)") {
                            ScrollView { VStack(alignment: .leading, spacing: 10) { StateRulesView(jurisdiction: j) }.padding() }.navigationTitle(j.displayName)
                        }.accessibilityIdentifier("state-rules-link")
                    } else {
                        NavigationLink("Choose where you live") { StatePickerView() }.accessibilityIdentifier("state-rules-link")
                    }
                } footer: {
                    Text("Laws about data brokers and your rights, by country and state, and how this app uses them.")
                }
                autoSection
                Section {
                    Toggle("Send forms for me by default", isOn: Binding(get: { model.autoSubmitDefault }, set: { model.setAutoSubmitDefault($0) }))
                        .accessibilityIdentifier("settings-auto-submit")
                } footer: {
                    Text("When on, a guide presses a form's own send button once the checks are cleared. Each guide has a \"Send it for me\" box to change this for the rest of the session. Turned off, you press the button yourself.")
                }
                if let lib = model.termsLibrary {
                    termsSection(lib)
                }
                Section("Open source") {
                    Text("Anyone can audit exactly what this app does.")
                    Link("View the code on GitHub", destination: AppInfo.repoURL)
                    Text("The repository is private until the pre-release checks finish.").font(.footnote).foregroundStyle(.secondary)
                }
                // The California DROP link only matters to someone who chose California.
                if model.showsCaliforniaDrop {
                    Section {
                        Link("California residents: one free request to every registered broker", destination: URL(string: "https://privacy.ca.gov/drop/")!)
                            .accessibilityIdentifier("california-drop")
                    } header: {
                        Text("Also worth doing")
                    } footer: {
                        Text("California's DROP, run by the state's privacy agency, sends one deletion request to every broker registered in California. It needs identity verification through the state, which Exnay cannot do for you.")
                    }
                }
                Section("Good to know") {
                    Text("Exnay is not affiliated with any data broker and is not legal advice. Broker pages change often, so a step may need updating.")
                }
            }
            .accessibilityIdentifier("about-list")
            .navigationTitle("About")
        }
    }
}

extension AboutView {
    @ViewBuilder
    fileprivate var autoSection: some View {
        Section {
            Toggle("Send opt-out requests every month", isOn: Binding(
                get: { model.autoSettings.optOutEnabled },
                set: { model.setAuto(scan: false, optOut: $0) }))
                .accessibilityIdentifier("settings-optout-toggle")
            NavigationLink("Activity and run now") { AutoActivityView() }.accessibilityIdentifier("auto-activity")
        } header: {
            Text("Automatic protection")
        } footer: {
            Text("Opt-out requests run monthly, when the app is open and when iOS lets it run in the background. It never solves a CAPTCHA or accepts terms for you without your separate approval. When you opt yourself out, it ticks a plain box saying you are the person the request is about.")
        }
    }

    @ViewBuilder
    fileprivate func termsSection(_ lib: TermsLibrary) -> some View {
        Section {
            if model.termsActive, let approval = model.termsApproval {
                Label("On, since \(Loc.date(approval.approvedAt))", systemImage: "checkmark.shield")
                    .accessibilityIdentifier("terms-status")
                Text("Exnay presses \"I agree\" for you only when every paragraph of a site's terms is on a list a person reviewed.")
                    .font(.footnote)
                NavigationLink("Acceptance log (\(model.consentLog.count))") { ConsentLogView() }
                Button("Turn off", role: .destructive) { model.revokeTerms() }.accessibilityIdentifier("terms-off")
            } else if model.termsReviewedCount > 0 {
                Label("Off", systemImage: "shield").accessibilityIdentifier("terms-status")
                Button("Review and allow…") { showApproval = true }.accessibilityIdentifier("terms-review")
            } else {
                Label("Off", systemImage: "shield").accessibilityIdentifier("terms-status")
                Text("None of the \(lib.paragraphs.count) terms paragraphs we have collected has been reviewed by a person yet, so nothing can be accepted for you. Sites that need terms accepted stay in your hands.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Accepting site terms for you")
        } footer: {
            Text("Off unless you turn it on. It never accepts terms that ban automated access, and every acceptance is logged here on this phone.")
        }
        .sheet(isPresented: $showApproval) { TermsApprovalView() }
    }
}

struct TermsApprovalView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Some people-search sites show an \"I agree to our terms\" prompt before results. If you allow this, Exnay presses that button for you, but only when every paragraph of the prompt and of the terms pages it links to is on a list that a person has read and judged acceptable.")
                    Text("Reviewed paragraphs: \(model.termsReviewedCount) of \(model.termsLibrary?.paragraphs.count ?? 0)").font(.footnote)
                }
                Section {
                    Text("In plain English, here is what these sites' terms say. It is a summary, not legal advice.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(TermsSummary.sections) { section in
                        DisclosureGroup(section.title) {
                            ForEach(section.bullets, id: \.self) { Text("• " + $0).font(.footnote) }
                        }
                    }
                    Text(TermsSummary.basis).font(.caption2).foregroundStyle(.secondary)
                } header: {
                    Text("What you would be agreeing to")
                }
                .accessibilityIdentifier("terms-tldr")
                Section("What stays off the table") {
                    Label("Terms that ban or imply automated access", systemImage: "nosign")
                    Label("Anything a reviewer ruled out", systemImage: "nosign")
                    Label("Any paragraph nobody has reviewed, including a changed one", systemImage: "nosign")
                }
                Section("You stay in control") {
                    Label("Approval covers this list version only; a change asks you again", systemImage: "arrow.triangle.2.circlepath")
                    Label("Every acceptance is logged on this phone", systemImage: "list.bullet.rectangle")
                    Label("Turn it off any time", systemImage: "hand.raised")
                }
                Section {
                    Button("Allow") { model.approveTerms(); dismiss() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("terms-allow")
                } footer: {
                    Text("You are agreeing to those terms through this app. If you would rather read each site's terms yourself, leave this off.")
                }
            }
            .navigationTitle("Accept terms for you?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
        }
    }
}

struct ConsentLogView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            if model.consentLog.isEmpty { Text("Nothing has been accepted for you yet.") }
            ForEach(Array(model.consentLog.enumerated().reversed()), id: \.offset) { _, e in
                VStack(alignment: .leading) {
                    Text(e.domain).font(.headline)
                    Text("\(Loc.date(e.date, time: true)) · \(e.paragraphs) paragraphs · list \(e.libraryVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Acceptance log")
    }
}

/// Pick or change where the owner lives (used when there is no address yet).
struct StatePickerView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            PlacePicker()
            Section { VStack(alignment: .leading, spacing: 10) { StateRulesView(jurisdiction: model.ownerJurisdiction, other: model.ownerCountry == "OTHER") } }
        }
        .navigationTitle("Where you live")
    }
}


/// What the Global Privacy Control is, who has to honor it, and how to turn it on in a browser.
struct GlobalPrivacyControlView: View {
    @EnvironmentObject var model: AppModel

    private var states: [Jurisdiction] { model.jurisdictions.filter { $0.gpc == true }.sorted { $0.displayName < $1.displayName } }

    var body: some View {
        List {
            if model.ownerJurisdiction?.gpc == true, let j = model.ownerJurisdiction {
                Section { Label(Loc.f("The law in %@ makes sites honor this signal.", j.displayName), systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
            Section("What it is") {
                Text("A setting in your browser that tells every site you visit: do not sell or share my data, and do not use it for targeted ads. It works by sending one extra line with each page request, so you set it once instead of clicking opt-out on every site.")
            }
            Section("What it does not do") {
                Text("It does not delete anything, and it does not reach data brokers that already hold your details, because those never see your browser. It is a good habit next to the opt-outs in this app, not a replacement.")
            }
            Section("In this app") {
                Text("Every opt-out page this app opens sends the signal, for everyone, wherever they live.")
            }
            Section("Outside these states") {
                Text("You can switch it on anywhere. Only the states below make sites obey it; elsewhere it is a request that some sites honor anyway and others ignore.")
            }
            Section("Turn it on in your browser") {
                Text("On a computer, Firefox has a setting for it: Settings, Privacy and Security, then \"Tell websites not to sell or share my data\".")
                Text("Brave and DuckDuckGo: already on by default.")
                Text("Safari has no built-in switch, so use one of those browsers for everyday browsing.")
            }
            Section("States that require sites to honor it") {
                Text(states.map(\.displayName).joined(separator: ", ")).font(.footnote)
                Text("Sources disagree on the full list and it is growing, so a state missing here may still require it.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Global Privacy Control")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// A walkthrough for turning the Global Privacy Control on. An app cannot change another browser's settings, so the person does each step.
struct GPCSetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section { Text("Apps on iPhone cannot change another browser's settings, so we walk you through it. The setting then applies to every site you browse, not only the ones in this app.").font(.footnote).foregroundStyle(.secondary) }
            Section("1. Use a browser that sends it") {
                Text("Brave and DuckDuckGo send the signal by default. Safari does not have a switch for it. Install one of them from the App Store.")
                Button("Get Brave") { openURL(URL(string: "https://brave.com/download/")!) }
                Button("Get DuckDuckGo") { openURL(URL(string: "https://duckduckgo.com/app")!) }
            }
            Section("2. Make it your default browser") {
                Text("Open the iPhone Settings app, find the browser in the list of apps, and choose it under Default Browser App. Links from other apps then open in it.")
            }
            Section("3. Check that it works") {
                Text("Open the check page in that browser. It tells you whether the signal is being sent.")
                Button("Open the check page") { openURL(URL(string: "https://globalprivacycontrol.org")!) }
            }
            Section {
                Button { model.setGPCSetupDone(!model.gpcSetupDone) } label: {
                    Label(model.gpcSetupDone ? "Marked completed. Tap to undo." : "Mark completed", systemImage: model.gpcSetupDone ? "checkmark.circle.fill" : "circle")
                }.accessibilityIdentifier("gpc-done")
                NavigationLink("What it is and who has to honor it") { GlobalPrivacyControlView() }
            }
        }
        .navigationTitle("Global Privacy Control")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// Shows the phone's advertising ID (the "MAID" or "IDFA" some brokers ask for) with a Copy button. The ID is read only when tracking is allowed
/// and is kept in memory while the screen is open, never stored. iOS asks for permission once; after a refusal only the Settings app can change it.
struct AdvertisingIDSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var id: String?
    @State private var status = AdvertisingID.status
    @State private var copied = false

    var body: some View {
        Section {
            if let id {
                Text(id).font(.system(.callout, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled).accessibilityIdentifier("maid-value")
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(id) }.accessibilityIdentifier("maid-copy")
            } else if status == .notDetermined {
                Text("Some brokers opt your phone out by its advertising ID. Allow it once to see the ID here so you can copy it.")
                Button("Show my advertising ID", systemImage: "iphone.badge.play") { Task { await reveal() } }.accessibilityIdentifier("maid-show")
            } else if status == .authorized {
                Text("Your phone's advertising ID is switched off or reset, so there is nothing to copy. In Settings, open Privacy & Security, then Apple Advertising, and make sure Personalized Ads is on, or turn tracking back on for Exnay.")
                openSettingsButton
            } else {
                Text("You asked Exnay not to track you, so it cannot read the ID. iOS only asks once. To change your mind, open Settings, tap Exnay, and turn on Allow Tracking.")
                openSettingsButton
            }
        } header: { Text("Advertising ID") } footer: {
            Text("Also called a MAID or IDFA. It is used only to fill brokers' opt-out forms that ask for it, and Exnay never stores it or sends it anywhere else.")
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }

    private var openSettingsButton: some View {
        Button("Open Settings", systemImage: "gearshape") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }.accessibilityIdentifier("maid-settings")
    }

    /// Re-reads the permission (it can change in the Settings app) and shows the ID if it is already allowed. Never prompts.
    private func refresh() async {
        status = AdvertisingID.status
        if status == .authorized || ProcessInfo.processInfo.arguments.contains("-fake-adid") { id = await AdvertisingID.current() } else { id = nil }
    }

    /// Triggers Apple's prompt, the only time the app can ask.
    private func reveal() async {
        id = await AdvertisingID.current()
        status = AdvertisingID.status
    }

    private func copy(_ value: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.expirationDate: Date().addingTimeInterval(60)])
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}
