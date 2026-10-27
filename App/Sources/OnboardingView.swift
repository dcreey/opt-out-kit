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
    /// Called with the person's answers to the automatic-protection page (scan is always false: nothing scans yet; monthly opt-out).
    var onDecide: ((Bool, Bool) -> Void)?
    let onFinish: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var index = 0
    /// The place whose rules the person has scrolled to the end of. Choosing a different place asks them to read again.
    @State private var placeRead: String?
    @FocusState private var emailFocused: Bool
    /// What is typed in the email box. The household is only written once typing pauses (each write rebuilds views and saves the encrypted file).
    @State private var emailDraft = ""
    private var emailValid: Bool { ContactEmail.isValid(emailDraft.trimmingCharacters(in: .whitespaces)) }
    private func commitEmail() { if emailDraft != model.contactEmail { model.setContactEmail(emailDraft) } }
    @State private var autoOptOut = true

    private var placeKey: String? { model.ownerJurisdiction?.id ?? (model.ownerCountry == "OTHER" ? "other" : nil) }
    private var rulesRead: Bool { placeKey == nil || placeRead == placeKey }
    /// The "accept site terms" page is only shown when there is something to accept (reviewed terms exist); otherwise it would ask for what cannot be given.
    private var showsTerms: Bool { model.termsReviewedCount > 0 }
    private var autoIndex: Int { pages.count + (showsTerms ? 3 : 2) }

    private let pages: [Page] = [
        Page(id: 0, symbol: "bolt.shield", title: Loc.t("We remove your data for you"),
             body: Loc.t("Exnay sends opt-out requests to data brokers on its own, from as many websites as it can. You only step in where a site needs a person."),
             bullets: [Loc.t("Every month it fills in and sends opt-out forms by itself"), Loc.t("It tells you the few steps that need you: bot checks, email links, ID")]),
        Page(id: 1, symbol: "lock.shield", title: Loc.t("Your data stays on this phone"),
             body: Loc.t("There is no Exnay server, no account and no tracking. What you enter is encrypted on this phone. The app only talks to the broker sites themselves, to opt you out."),
             bullets: [Loc.t("Open source: anyone can audit the code"), Loc.t("Lost phone with no backup means lost data; a normal iPhone backup carries it"), Loc.t("Each site sees only the details its form needs")]),
        Page(id: 2, symbol: "person.crop.circle", title: Loc.t("Set up your profile"),
             body: Loc.t("Tap Profile to enter your legal name and current address (both required), plus any other names and past addresses."),
             bullets: [Loc.t("Nicknames and old names find more listings"), Loc.t("Past addresses find more listings, because brokers keep old ones on file")]),
    ]

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Picker("Language", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    ForEach(AppModel.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.menu).accessibilityIdentifier("onboarding-language")
            }
            .padding(.horizontal)
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
                        Image(systemName: "envelope.badge.shield.half.filled").font(.system(size: 64)).foregroundStyle(.tint).padding(.top, 40)
                        Text("Your email address").font(.title.bold())
                        Text("Required. This one address goes on every opt-out form and every data-deletion request.")
                            .multilineTextAlignment(.center)
                        TextField("you@example.com", text: $emailDraft)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textContentType(.emailAddress).textFieldStyle(.roundedBorder).focused($emailFocused)
                            .accessibilityIdentifier("onboarding-email")
                            .onAppear { if emailDraft.isEmpty { emailDraft = model.contactEmail } }
                            .onSubmit { commitEmail() }
                            .task(id: emailDraft) {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                if !Task.isCancelled { commitEmail() }
                            }
                        Text(EmailExplainer.text).font(.footnote).foregroundStyle(.secondary)
                        if !emailValid {
                            Label("Enter a valid email address to continue.", systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("onboarding-email-needed")
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .tag(pages.count)
                ScrollView {
                    // Lazy, so the end marker only appears once the person has scrolled to the bottom.
                    LazyVStack(spacing: 16) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 64)).foregroundStyle(.tint).padding(.top, 40)
                        Text("Where do you live?").font(.title.bold())
                        Text("Laws about data brokers differ by country and, in the United States, by state. Choose yours and we show what it means for you and what we do about it.")
                            .multilineTextAlignment(.center)
                        PlacePicker()
                        StateRulesView(jurisdiction: model.ownerJurisdiction, other: model.ownerCountry == "OTHER", onReachedEnd: { placeRead = placeKey })
                        if placeKey != nil, !rulesRead {
                            Label("Scroll to the bottom to continue.", systemImage: "arrow.down.circle")
                                .font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("onboarding-state-scroll-hint")
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .tag(pages.count + 1)
                if showsTerms {
                    ScrollView { TermsOnboardingPage().padding(.horizontal, 28) }
                        .tag(pages.count + 2)
                }
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "bolt.shield").font(.system(size: 64)).foregroundStyle(.tint).padding(.top, 40)
                        Text("Automatic protection").font(.title.bold())
                        AutoExplainer()
                        VStack { AutoToggles(scan: .constant(false), optOut: $autoOptOut) }
                        if autoOptOut {
                            Label("To start, we need your legal name and current address. We ask for them next.", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .tag(autoIndex)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Our own page dots, below the content: the system ones sit on top of it and cover the last lines.
            HStack(spacing: 8) {
                ForEach(0...autoIndex, id: \.self) { i in
                    Circle().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                }
            }
            .padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(index + 1) of \(autoIndex + 1)")
            .accessibilityIdentifier("onboarding-page-dots")

            HStack {
                // The email is required, so Skip goes to it instead of leaving.
                Button("Skip") { withAnimation { index = max(index, pages.count) } }.accessibilityIdentifier("onboarding-skip")
                Spacer()
                if index < autoIndex {
                    Button("Next") { commitEmail(); withAnimation { index += 1 } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding-next")
                        .disabled((index == pages.count && !emailValid) || (index == pages.count + 1 && !rulesRead))
                } else {
                    Button(autoOptOut ? Loc.t("Turn on and start") : "Start") {
                        commitEmail()
                        onDecide?(false, autoOptOut)
                        onFinish()
                        // They said yes: ask for what is missing now, instead of leaving automatic opt-out switched on but waiting.
                        if autoOptOut { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.requireProfile { } } }
                    }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding-done")
                    .disabled(!emailValid || !rulesRead)
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

/// What a place's law means for the person and what the app does about it, from the facts in `jurisdictions/`. Its lines are direct
/// children of whatever stack holds it, so inside a lazy stack the end marker (`onReachedEnd`) only fires once the person has
/// scrolled to the bottom. Put it in a stack of your own where that does not matter.
struct StateRulesView: View {
    @EnvironmentObject var model: AppModel
    let jurisdiction: Jurisdiction?
    var other = false
    var onReachedEnd: (() -> Void)?

    var body: some View {
        Group {
            if let j = jurisdiction {
                ForEach(Array(model.statements(for: j).enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(line.text, systemImage: line.symbol).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if let url = line.url.flatMap(URL.init(string:)) {
                            Link("Read it at \(url.host ?? "the source")", destination: url).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !j.sourceLinks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Where we found this").font(.footnote.bold())
                        ForEach(j.sourceLinks) { link in
                            Link(destination: URL(string: link.url)!) {
                                Label("\(link.title) (\(URL(string: link.url)?.host ?? ""))", systemImage: "link").font(.caption)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("state-rules-sources")
                }
                Text("Law details last reviewed \(j.reviewed). They change slowly and we re-check them regularly.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("state-rules-reviewed")
            } else if other {
                Label("We do not have your country's rules yet. The opt-out forms in this app work from anywhere a broker accepts requests, and we will add country laws over time.",
                      systemImage: "globe").font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let onReachedEnd {
                Color.clear.frame(height: 1).onAppear(perform: onReachedEnd).accessibilityHidden(true)
            }
        }
    }
}

/// Country first, then, for the United States, the state.
struct PlacePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Country", selection: Binding<String?>(get: { model.ownerCountry }, set: { model.setOwnerCountry($0) })) {
            Text("Choose your country").tag(String?.none)
            ForEach(model.countryOptions, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
            Text("Another country").tag(String?.some("OTHER"))
        }
        .pickerStyle(.menu).accessibilityIdentifier("onboarding-country")
        if model.ownerCountry == "US" {
            Picker("Your state", selection: Binding<String?>(get: { model.ownerState }, set: { model.setOwnerState($0) })) {
                Text("Choose your state").tag(String?.none)
                ForEach(USStates.all, id: \.code) { Text(L10n.t($0.name)).tag(String?.some($0.code)) }
            }
            .pickerStyle(.menu).accessibilityIdentifier("onboarding-state")
        }
    }
}

/// The walkthrough page that asks, in plain words, whether the app may press "I agree" on broker sites' terms prompts. Off unless the
/// person allows it. It can only be allowed once people have reviewed paragraphs of those terms; until then it says so.
struct TermsOnboardingPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield").font(.system(size: 64)).foregroundStyle(.tint).padding(.top, 40)
            Text("Accept site terms for you?").font(.title.bold()).multilineTextAlignment(.center)
            Text("Some broker sites show an \"I agree to our terms\" prompt before their opt-out form. If you allow it, we press that button for you, but only when every paragraph of the prompt, and of the terms pages it links to, is on a list a person has read and judged acceptable. That keeps more opt-outs hands-free.")
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                Text("In plain English, what these sites' terms say").font(.headline)
                ForEach(TermsSummary.sections) { section in
                    DisclosureGroup(section.title) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(section.bullets, id: \.self) { Text("• " + $0).font(.footnote) }
                        }
                    }
                }
                Text(TermsSummary.basis).font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("onboarding-terms-tldr")
            VStack(alignment: .leading, spacing: 6) {
                Label("Never terms that ban or imply automated access", systemImage: "nosign")
                Label("Never a paragraph nobody has reviewed, including a changed one", systemImage: "nosign")
                Label("Every acceptance is logged on this phone, and you can turn it off any time", systemImage: "list.bullet.rectangle")
            }
            .font(.footnote)
            Text("The terms are each site's own words, in the language that site shows you. If a site offers its terms in your language we use that version; if not, the original stays as it is. They are never machine-translated.")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding-terms-language")
            status
        }
    }

    @ViewBuilder private var status: some View {
        if model.termsActive {
            Label("On. You can turn it off in About.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityIdentifier("onboarding-terms-status")
            Button("Turn off", role: .destructive) { model.revokeTerms() }.accessibilityIdentifier("onboarding-terms-off")
        } else if model.termsReviewedCount > 0 {
            Text("You are agreeing to those terms through this app. If you would rather read each site's terms yourself, leave this off.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Allow") { model.approveTerms() }.buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding-terms-allow")
            Text("Not now? Just tap Next. Sites that need terms accepted stay in your hands.").font(.footnote).foregroundStyle(.secondary)
        } else {
            Label("Not available yet. None of the \(model.termsLibrary?.paragraphs.count ?? 0) terms paragraphs we have collected has been reviewed by a person, so nothing can be accepted for you. Sites that need terms accepted stay in your hands until a reviewed list ships, and we will ask you then.",
                  systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding-terms-status")
        }
    }
}
