import SwiftUI

/// The walkthrough shown the first time a person opens a guided flow (Solve and send, or the manual guide): what they are looking at, what the
/// … menu holds, what a site needs, what to make of the legal wording, and the email follow-ups. It can be skipped, and it is replayed from About.
/// It is separate from the first-install walkthrough (`OnboardingView`).
struct GuidedIntroView: View {
    let onDone: () -> Void
    @State private var index = 0
    private let count = 5

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $index) {
                page(symbol: "rectangle.split.1x2", title: "This is a guided site") {
                    Text("Exnay's guide is the black part on top. The site's own opt-out page is below the gold line. The guide fills the page in for you and tells you what is left for you to do.")
                    GuidedIntroExample()
                    Text("Each site is a little different. Follow the guide, and tap Next when the page says it is done.").font(.footnote).foregroundStyle(.secondary)
                }.tag(0)
                page(symbol: "ellipsis.circle", title: "The … menu") {
                    Text("Tap the … button in the guide any time.")
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Copy link: the page's address", systemImage: "link")
                        Label("Refresh the page: reload it, and your details are put back", systemImage: "arrow.clockwise")
                        Label("Fill the form again: if something was cleared or missed", systemImage: "square.and.pencil")
                        Label("My data: tap any detail to copy it, even your advertising ID, for a box we did not fill", systemImage: "person.text.rectangle")
                        Label("Not working: tell us what went wrong with this site", systemImage: "exclamationmark.bubble")
                        Label("Skip or cancel: leave a site for later", systemImage: "forward")
                    }.font(.callout)
                }.tag(1)
                page(symbol: "checklist", title: "What a site needs") {
                    Text("Most sites want the same few things.")
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Your name, address and email, which we fill in", systemImage: "person.text.rectangle")
                        Label("A bot check, \"I am human\", which only you can tick", systemImage: "checkmark.square")
                        Label("Sometimes a code or an ID, which you type or copy", systemImage: "number")
                        Label("Then Send. With Auto-send on, we press it when the page is ready. Turn it off to press it yourself.", systemImage: "bolt.fill")
                    }.font(.callout)
                }.tag(2)
                page(symbol: "exclamationmark.triangle", title: "The scary wording") {
                    Text("Most opt-out pages open with a wall of legal terms: you must prove who you are, we cannot promise anything, you agree to this and that. A lot of it is written to make you feel you have no right to opt out.")
                    Text("You do. You do not need to read it all, and you do not need to agree to more than the form asks. Fill in the form, send it, and move on. If a page asks for something odd, like a photo of your ID, choose Not working in the … menu or skip the site.")
                        .font(.callout)
                }.tag(3)
                page(symbol: "envelope.badge", title: "Emails after you send") {
                    Text("Many sites send you an email after you submit, with a link or a code to confirm it. Until you tap it, the opt-out is not done.")
                    VStack(alignment: .leading, spacing: 12) {
                        Label("When a page says to check your email, we offer to track it", systemImage: "bell")
                        Label("Open the confirmation in your mail, and share or copy its link into Email links", systemImage: "envelope.open")
                        Label("Email links finishes it, and the site counts as done", systemImage: "checkmark.circle")
                    }.font(.callout)
                }.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { i in
                    Circle().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                }
            }
            .padding(.top, 8).accessibilityElement(children: .ignore).accessibilityLabel("Page \(index + 1) of \(count)").accessibilityIdentifier("guided-intro-dots")

            HStack {
                Button("Skip", action: onDone).accessibilityIdentifier("guided-intro-skip")
                Spacer()
                if index < count - 1 {
                    Button("Next") { withAnimation { index += 1 } }.buttonStyle(.borderedProminent).accessibilityIdentifier("guided-intro-next")
                } else {
                    Button("Got it", action: onDone).buttonStyle(.borderedProminent).accessibilityIdentifier("guided-intro-done")
                }
            }
            .padding()
        }
    }

    private func page<C: View>(symbol: String, title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 56)).foregroundStyle(.tint).padding(.top, 32)
                Text(title).font(.title.bold()).multilineTextAlignment(.center)
                content()
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
    }
}

/// A picture of a guided screen: the black guide on top, the gold line, the site's page below.
private struct GuidedIntroExample: View {
    var body: some View {
        VStack(spacing: 0) {
            GuideSurface(topInset: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "ellipsis.circle").font(.title2)
                    Text("Site 2 of 15").font(.caption.bold()).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("Next step").font(.callout.bold()).foregroundStyle(.black).padding(.horizontal, 14).padding(.vertical, 8).background(Color.exnayGold, in: Capsule())
                }
                Text("Tick \"I am human\", then we send it.").font(.subheadline.bold()).foregroundStyle(.white)
            }
            GuideBoundary()
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Do Not Sell My Personal Information").font(.footnote.bold()).foregroundStyle(.black)
                ForEach(["Name", "Email", "Address"], id: \.self) { f in
                    Text(verbatim: f).font(.caption).foregroundStyle(.gray).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5)))
                }
                Label { Text(verbatim: "I am human") } icon: { Image(systemName: "square") }.font(.caption).foregroundStyle(.black)
                Text(verbatim: "Submit").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6).background(Color.blue, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.4)))
        .accessibilityElement(children: .ignore).accessibilityLabel(Loc.t("An example: the guide on top, the site's page below"))
        .environment(\.colorScheme, .light)
    }
}

extension View {
    /// Shows `GuidedIntroView` over a guided flow the first time it is opened (the caller sets `shown`); the flow waits for it to close.
    func guidedIntro(_ shown: Binding<Bool>, onDone: @escaping () -> Void) -> some View {
        fullScreenCover(isPresented: shown) { GuidedIntroView(onDone: onDone) }
    }
}
