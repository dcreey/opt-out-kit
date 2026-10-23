import OptOutKitCore
import AdSupport
import AppTrackingTransparency

/// The phone's advertising ID, for the data brokers that opt a device out by it (their forms ask for a "MAID" or "IDFA"). Reading it needs
/// the person's permission through Apple's tracking prompt, and the prompt text says it is only given to those brokers. It is not stored.
enum AdvertisingID {
    /// Asks once (if the person has not been asked), then returns the ID, or nil when permission was refused or ad tracking is off.
    @MainActor
    static func current() async -> String? {
        var status = ATTrackingManager.trackingAuthorizationStatus
        if status == .notDetermined { status = await ATTrackingManager.requestTrackingAuthorization() }
        guard status == .authorized else { return nil }
        let id = ASIdentifierManager.shared().advertisingIdentifier
        return id.uuidString == "00000000-0000-0000-0000-000000000000" ? nil : id.uuidString
    }

    /// Whether any form we are about to send asks for the advertising ID.
    static func isAsked(by entries: [DirectoryEntry]) -> Bool {
        entries.contains { e in e.optOutForm?.fields.contains { f in
            (f.name + " " + f.label).range(of: "\\bmaid\\b|\\bidfa\\b|\\baaid\\b|advertising.?(id|identifier)|mobile.?ad", options: [.regularExpression, .caseInsensitive]) != nil } ?? false }
    }
}
