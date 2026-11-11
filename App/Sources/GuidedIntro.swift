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
                page(symbol: "rectangle.split.1x2", title: "This is a guided site", lead: "Follow the black guide on top. The site's own page is below it.") {
                    Text("The guide fills the page in for you and tells you the one thing left for you to do. When the page says it is done, tap Next.")
                    GuidedIntroExample()
                    Text("Each site is a little different, so read the guide's line each time.").font(.footnote).foregroundStyle(.secondary)
                }.tag(0)
                page(symbol: "ellipsis.circle", title: "The … menu", lead: "If something goes wrong, tap the … button in the guide.") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Copy link: copy this page's web address", systemImage: "link")
                        Label("Open in my browser: finish in Safari or your usual browser. When you come back we ask whether you finished", systemImage: "safari")
                        Label("Refresh the page: reload it and fill your details in again", systemImage: "arrow.clockwise")
                        Label("Fill the form again: if the page cleared a box or we missed one", systemImage: "square.and.pencil")
                        Label("My data: tap your name, address, phone or email to copy it, then paste it into a box we did not fill. Your advertising ID is here too", systemImage: "person.text.rectangle")
                        Label("There is another email step: the site said it will email you more than once", systemImage: "envelope.badge")
                        Label("Not working: the page is broken. Pick what went wrong and Exnay sets this site aside to try again later. Nothing is sent anywhere", systemImage: "exclamationmark.bubble")
                        Label("Skip or cancel: leave this site and come back to it later", systemImage: "forward")
                    }.font(.callout)
                }.tag(1)
                page(symbol: "checklist", title: "What a site needs", lead: "Most sites need the same few things.") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Your name, address and email. We fill these in", systemImage: "person.text.rectangle")
                        Label("A human check: the \"I am not a robot\" box or a picture puzzle. Only you can pass it", systemImage: "checkmark.square")
                        Label("Sometimes a code or an ID. You type or copy it", systemImage: "number")
                        Label("Then Send. With Auto-send on, we press the page's Send button once the checks are done. Turn it off to press it yourself", systemImage: "bolt.fill")
                    }.font(.callout)
                }.tag(2)
                page(symbol: "exclamationmark.triangle", title: "The scary wording", lead: "You have the right to opt out, whatever the page says.") {
                    Text("Most opt-out pages open with a wall of legal terms: you must prove who you are, we cannot promise anything, you agree to this and that. Much of it is written to make you feel you have no right to opt out. You do.")
                    guideText(Loc.t("You do not need to read it all, and you do not need to agree to more than the form asks. Fill in the form, send it, and move on. If a page asks for something odd, like a photo of your ID, choose Not working in the … menu or skip the site."))
                        .font(.callout)
                }.tag(3)
                page(symbol: "envelope.badge", title: "Emails after you send", lead: "A site is not finished until you tap the link in its email.") {
                    Text("Many sites email you a link or a code after you send the form, and only remove you once you confirm it. The email can take a few minutes, so look in your spam folder too.")
                    VStack(alignment: .leading, spacing: 12) {
                        Label("When the page says to check your email, we ask whether an email follows. Say yes, and the site goes on your waiting list", systemImage: "bell")
                        Label("Open the email in your mail app. Press and hold its link, tap Share, and choose Exnay. Or copy the link and paste it into the Email links tab", systemImage: "envelope.open")
                        Label("Exnay opens the page and fills it in. When the page says you are done, tap Mark completed", systemImage: "checkmark.circle")
                        Label { guideText(Loc.t("Some sites send more than one email. If another comes, tap There is another email step in the … menu, and the site stays on your list")) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
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

    /// `lead` is the one thing to take from the page, in bold under the title; the rest explains it.
    private func page<C: View>(symbol: String, title: String, lead: String, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 56)).foregroundStyle(.tint).padding(.top, 32)
                guideText(Loc.t(title)).font(.title.bold()).multilineTextAlignment(.center)
                guideText(Loc.t(lead)).font(.title3.bold()).multilineTextAlignment(.center).accessibilityIdentifier("guided-intro-lead")
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
