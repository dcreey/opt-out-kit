import SwiftUI
import WebKit
import OptOutKitCore

extension Color {
    /// The gold of the app icon.
    static let exnayGold = Color(red: 0.98, green: 0.725, blue: 0.2)
}

/// The line between our guide (above) and the site's own page (below): the icon's gold, broken by the icon and the app's name, so the two
/// can never be mistaken for each other. Both the semi-automated and the manual guide use it.
struct GuideBoundary: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.exnayGold).frame(width: 14, height: 4)
            Image("GuideIcon").resizable().frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Exnay").font(.caption.bold()).foregroundStyle(Color.exnayGold)
            Rectangle().fill(Color.exnayGold).frame(height: 4)
        }
        .padding(.top, 4).padding(.bottom, 6)
        .background(Color.black)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.exnayGold).frame(height: 0) }
        .accessibilityElement(children: .ignore).accessibilityLabel("Exnay").accessibilityIdentifier("guided-banner")
    }
}

/// Black ground for the guide's controls and words; it runs up behind the status bar.
struct GuideSurface<Content: View>: View {
    let topInset: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 14).padding(.top, topInset + 6).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black)
            .tint(Color.exnayGold)
            .environment(\.colorScheme, .dark)
    }
}

/// The primary button of the guide: gold with dark words.
struct GuidePrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.bold()).foregroundStyle(Color.black).lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.exnayGold.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

/// A pill for the guide's own choices: gold and solid when it is on, a gold outline when it is not.
struct GuidePillStyle: ButtonStyle {
    var filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(filled ? Color.black : Color.exnayGold)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(filled ? Color.exnayGold : Color.exnayGold.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(Color.exnayGold, lineWidth: filled ? 0 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// "Auto-send": on by default (Settings changes the default). Turned off, a guide fills the form in and the person presses the page's own button.
/// The choice lasts until the app is closed.
struct AutoSubmitToggle: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let on = model.autoSubmit
        Button { model.autoSubmitSession = !on } label: {
            Label(on ? Loc.t("Auto-send ON") : Loc.t("Auto-send OFF"), systemImage: on ? "bolt.fill" : "bolt.slash")
        }
        .buttonStyle(GuidePillStyle(filled: on))
        .accessibilityIdentifier("auto-submit-toggle").accessibilityValue(on ? "on" : "off")
    }
}

/// The page actions every guide's … menu starts with, so Solve and send, the guided steps and Email links offer the same three things in the same order:
/// copy the page's address, refresh it (reload, then the details are put back: `PageFlow.reloadThenRefill`) and fill the form in.
extension DetailKind {
    var title: LocalizedStringKey {
        switch self {
        case .name: "Name"
        case .email: "Email"
        case .phone: "Phone"
        case .address: "Address"
        case .birthdate: "Birth date"
        }
    }
}

/// "Is it completely done?" (`FinishQuestion`): the same words and buttons in every flow that has a person on screen.
private struct FinishQuestionAlert: ViewModifier {
    @ObservedObject var question: FinishQuestion
    func body(content: Content) -> some View {
        let ask = question.pending
        content.alert("Is it completely done?", isPresented: Binding(get: { ask != nil }, set: { if !$0 { question.dismiss() } })) {
            Button("Yes, completely done") { question.answer(.done) }.accessibilityIdentifier("finish-done")
            Button("An email is still to come") { question.answer(.emailFollows) }.accessibilityIdentifier("finish-email")
            Button("I am not sure") { question.answer(.unsure) }.accessibilityIdentifier("finish-unsure")
            if ask?.allowsNotYet == true { Button("Not yet", role: .cancel) { question.answer(.notYet) }.accessibilityIdentifier("finish-not-yet") }
        } message: {
            Text(ask?.pageSaidEmail == true
                 ? "This page mentions an email. Some sites send more than one, each with a step to do. If you are not sure, say so and we keep it on your waiting list."
                 : "Some sites send an email afterwards with one more step, sometimes more than one. If you are not sure, say so and we keep it on your waiting list.")
        }
    }
}

extension View {
    func finishQuestionAlert(_ question: FinishQuestion) -> some View { modifier(FinishQuestionAlert(question: question)) }
}

/// "Open in my browser" from a guide's … menu: the page goes to the phone's default browser, and the question "Did you complete it?" is already waiting when the
/// person comes back, as with another mail app. Yes finishes the site the way that flow finishes one; No changes nothing and the guide stays where it was.
@MainActor
final class BrowserHandoff: ObservableObject {
    @Published var asking = false
    func open(_ url: URL, launch: (URL) -> Void = { UIApplication.shared.open($0) }) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        asking = true
        launch(url)
    }
    func answer(completed: Bool, finish: () -> Void) { asking = false; if completed { finish() } }
}

private struct BrowserHandoffAlert: ViewModifier {
    @ObservedObject var handoff: BrowserHandoff
    let onCompleted: () -> Void
    func body(content: Content) -> some View {
        content.alert("Did you complete it?", isPresented: Binding(get: { handoff.asking }, set: { _ in })) {
            Button("Yes, I completed it") { handoff.answer(completed: true, finish: onCompleted) }.accessibilityIdentifier("browser-handoff-yes")
            Button("No", role: .cancel) { handoff.answer(completed: false, finish: onCompleted) }.accessibilityIdentifier("browser-handoff-no")
        } message: { Text("You opened this site in your browser. Say yes only if you finished the request there.") }
    }
}

extension View {
    func browserHandoffAlert(_ handoff: BrowserHandoff, onCompleted: @escaping () -> Void) -> some View { modifier(BrowserHandoffAlert(handoff: handoff, onCompleted: onCompleted)) }
}

enum PageMenu {
    /// - fillTitle: "Fill the form again" where the guide fills for you, "Fill in my details" where you start it.
    /// - details: the person's own details, copied one at a time from "My data", with the advertising ID (MAID) first.
    /// - idPrefix: prefix of the accessibility identifiers (assisted, guided, link).
    @MainActor @ViewBuilder
    static func items(web: WKWebView?, fillTitle: LocalizedStringKey = "Fill the form again", idPrefix: String, fillID: String = "fill-again", canFill: Bool = true, details: [DetailGroup] = [], browser: BrowserHandoff? = nil, anotherEmailStep: (() -> Void)? = nil, fill: @escaping () async -> Void) -> some View {
        if let url = web?.url {
            Button { UIPasteboard.general.string = url.absoluteString } label: { Label("Copy link", systemImage: "link") }
            if let browser {
                Button { browser.open(url) } label: { Label("Open in my browser", systemImage: "safari") }.accessibilityIdentifier("\(idPrefix)-open-browser")
            }
        }
        if let anotherEmailStep {
            Button(action: anotherEmailStep) { Label("There is another email step", systemImage: "envelope.badge") }.accessibilityIdentifier("\(idPrefix)-email-step")
        }
        if let web {
            Button {
                Task { await PageFlow.reloadThenRefill(reload: { web.reload() }, refill: fill) }
            } label: { Label("Refresh the page", systemImage: "arrow.clockwise") }.accessibilityIdentifier("\(idPrefix)-refresh")
            Button { Task { await fill() } } label: { Label(fillTitle, systemImage: "square.and.pencil") }
                .disabled(!canFill).accessibilityIdentifier("\(idPrefix)-\(fillID)")
        }
        Menu {
            Section("Advertising ID (MAID)") {
                if let id = AdvertisingID.ifAllowed {
                    Button(id) { AdvertisingID.copy(id) }.accessibilityIdentifier("\(idPrefix)-maid")
                } else if AdvertisingID.status == .notDetermined {
                    Button("Show my advertising ID") { Task { if let id = await AdvertisingID.current() { AdvertisingID.copy(id) } } }.accessibilityIdentifier("\(idPrefix)-maid")
                } else {
                    Button("Allow the advertising ID in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.accessibilityIdentifier("\(idPrefix)-maid")
                }
            }
            ForEach(details, id: \.kind) { group in
                Section(group.kind.title) {
                    ForEach(group.values, id: \.self) { value in
                        Button(value) {
                            UIPasteboard.general.string = value
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                }
            }
        } label: { Label("My data", systemImage: "person.text.rectangle") }.accessibilityIdentifier("\(idPrefix)-my-data")
    }
}


/// The "Was this sent?" question of `SentQuestion`, the same wording and buttons wherever a flow asks it.
private struct SentQuestionAlert: ViewModifier {
    @ObservedObject var question: SentQuestion
    func body(content: Content) -> some View {
        content.alert("Was this sent?", isPresented: Binding(get: { question.pending != nil }, set: { if !$0 { question.dismiss() } })) {
            Button("Yes, it was sent") { question.answer(sent: true) }
            Button("No, stay on this page", role: .cancel) { question.answer(sent: false) }
        } message: {
            Text("The page shows a confirmation, but we did not see you press anything. If the page sent it, or you sent it, choose Yes.")
        }
    }
}

extension View {
    func sentQuestionAlert(_ question: SentQuestion) -> some View { modifier(SentQuestionAlert(question: question)) }
}
