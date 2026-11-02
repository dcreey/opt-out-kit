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

enum PageMenu {
    /// - fillTitle: "Fill the form again" where the guide fills for you, "Fill in my details" where you start it.
    /// - details: the person's own details, copied one at a time from "My data", with the advertising ID (MAID) last.
    /// - idPrefix: prefix of the accessibility identifiers (assisted, guided, link).
    @MainActor @ViewBuilder
    static func items(web: WKWebView?, fillTitle: LocalizedStringKey = "Fill the form again", idPrefix: String, fillID: String = "fill-again", canFill: Bool = true, details: [DetailGroup] = [], fill: @escaping () async -> Void) -> some View {
        if let url = web?.url {
            Button { UIPasteboard.general.string = url.absoluteString } label: { Label("Copy link", systemImage: "link") }
        }
        if let web {
            Button {
                Task { await PageFlow.reloadThenRefill(reload: { web.reload() }, refill: fill) }
            } label: { Label("Refresh the page", systemImage: "arrow.clockwise") }.accessibilityIdentifier("\(idPrefix)-refresh")
            Button { Task { await fill() } } label: { Label(fillTitle, systemImage: "square.and.pencil") }
                .disabled(!canFill).accessibilityIdentifier("\(idPrefix)-\(fillID)")
        }
        Menu {
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
        } label: { Label("My data", systemImage: "person.text.rectangle") }.accessibilityIdentifier("\(idPrefix)-my-data")
    }
}
