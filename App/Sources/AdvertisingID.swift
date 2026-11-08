import OptOutKitCore
import SwiftUI
import AdSupport
import AppTrackingTransparency

/// The phone's advertising ID, for the data brokers that opt a device out by it (their forms ask for a "MAID" or "IDFA"). Reading it needs
/// the person's permission through Apple's tracking prompt, and the prompt text says it is only given to those brokers. It is not stored.
enum AdvertisingID {
    static var status: ATTrackingManager.AuthorizationStatus { ATTrackingManager.trackingAuthorizationStatus }

    /// Asks once (if the person has not been asked), then returns the ID, or nil when permission was refused or ad tracking is off.
    @MainActor
    static func current() async -> String? {
        #if DEBUG
        // Simulator work: the simulator has no advertising ID, so `-fake-adid` stands one in (never on a device).
        if ProcessInfo.processInfo.arguments.contains("-fake-adid") { return "11111111-2222-3333-4444-555555555555" }
        #endif
        var status = ATTrackingManager.trackingAuthorizationStatus
        if status == .notDetermined { status = await ATTrackingManager.requestTrackingAuthorization() }
        guard status == .authorized else { return nil }
        let id = ASIdentifierManager.shared().advertisingIdentifier
        return id.uuidString == "00000000-0000-0000-0000-000000000000" ? nil : id.uuidString
    }

    /// The ID when permission is already given (never prompts), else nil.
    static var ifAllowed: String? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fake-adid") { return "11111111-2222-3333-4444-555555555555" }
        #endif
        guard status == .authorized else { return nil }
        let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return id == "00000000-0000-0000-0000-000000000000" ? nil : id
    }

    /// Puts a value on the clipboard for a minute only, the way the About screen does for the ID.
    @MainActor
    static func copy(_ value: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.expirationDate: Date().addingTimeInterval(60)])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Whether one form's fields ask for it.
    static func isAsked(by fields: [FormField]) -> Bool {
        fields.contains { f in (f.name + " " + f.label).range(of: "\\bmaid\\b|\\bidfa\\b|\\baaid\\b|advertising.?(id|identifier)|mobile.?ad|device.?(id|identifier)", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Whether any form we are about to send asks for the advertising ID.
    static func isAsked(by entries: [DirectoryEntry]) -> Bool {
        entries.contains { e in e.optOutForm?.fields.contains { f in
            (f.name + " " + f.label).range(of: "\\bmaid\\b|\\bidfa\\b|\\baaid\\b|advertising.?(id|identifier)|mobile.?ad", options: [.regularExpression, .caseInsensitive]) != nil } ?? false }
    }
}


/// Said before Apple's tracking prompt appears, so the prompt is not a surprise.
struct AdIDExplainer: View {
    let siteName: String
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.badge.play").font(.system(size: 56)).foregroundStyle(.tint).padding(.top, 24)
            Text("Opt your phone out of ad tracking").font(.title2.bold()).multilineTextAlignment(.center)
            Text("\(siteName) tracks people for advertising by the unique ID of their phone. To opt your phone out, it needs that ID in your request.")
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                Label("Next, iOS asks \"Allow Exnay to track you?\" Tap Allow. That is Apple's wording for sharing this one ID.", systemImage: "hand.tap")
                Label("We do nothing else with it. It goes only into the opt-out you send, to opt your device out of tracking on the web.", systemImage: "lock.shield")
                Label("We never store it and never send it anywhere else.", systemImage: "internaldrive.badge.xmark")
            }.font(.callout)
            Text("If you tap Ask App Not to Track, the email goes without it and the site may not be able to find your phone.").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button(action: onContinue) { Text("Continue").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("adid-continue")
            Button("Send without it", action: onSkip).accessibilityIdentifier("adid-skip")
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .presentationDetents([.large])
    }
}


/// The one place the person is asked to share the advertising ID with this app (Apple's tracking prompt), used by the walkthrough and About.
/// Before a choice it is a button that raises Apple's prompt; after one it says what was chosen, and after a refusal points to Settings, the only
/// place iOS lets it be changed.
struct AdIDPermissionControl: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = AdvertisingID.status
    /// Called after the prompt is answered, so a screen can show the ID.
    var onAnswered: () -> Void = {}

    private var allowed: Bool { status == .authorized || ProcessInfo.processInfo.arguments.contains("-fake-adid") }

    var body: some View {
        VStack(spacing: 10) {
            if allowed {
                Label("Shared with Exnay", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("adid-allowed")
            } else if status == .notDetermined {
                Button { Task { _ = await AdvertisingID.current(); status = AdvertisingID.status; onAnswered() } } label: {
                    Label("Allow advertising ID", systemImage: "iphone.badge.play").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("adid-allow")
            } else {
                Text("Sharing is off, and iOS asks only once. To turn it on, open Settings, then Privacy & Security, then Tracking, and switch Exnay on. If Exnay is not in that list, first switch on Allow Apps to Request to Track. You can also open Settings, tap Exnay and turn on Allow Tracking if it is shown there. Without it, forms that ask for the ID are sent without it.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Settings", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.accessibilityIdentifier("adid-settings")
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { status = AdvertisingID.status } }
    }
}
