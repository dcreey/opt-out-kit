import SwiftUI
import OptOutKitCore

/// A short "how this works" card, shown once the first time a person reaches a kind of screen.
struct CoachGuide: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let points: [String]

    static let allIDs = ["sites", "semi", "manual"]

    static var sites: CoachGuide {
        CoachGuide(id: "sites", symbol: "list.number", title: Loc.t("How your queue works"), points: [
            Loc.t("Tasks are ranked: your official removal service first, then what the app does for you, then the rest, nearest first."),
            Loc.t("One task can handle many sites. A site is never listed twice."),
            Loc.t("Search any site by name or web address to find its task."),
            Loc.t("Tap a task to see exactly what it will do before you start."),
        ])
    }
    static var semiAutomatic: CoachGuide {
        CoachGuide(id: "semi", symbol: "hand.point.up.left", title: Loc.t("How a semi-automated task works"), points: [
            Loc.t("The app fills in the site's form with only the details it asks for."),
            Loc.t("You solve the human check, and pick your own listing if the site asks. We never do that for you."),
            Loc.t("Some sites email you a link to confirm. That tap is yours too."),
            FollowUpNote.text,
        ])
    }
    /// The guide for a task done this way, or none for what the app does by itself.
    static func forMethod(_ m: OptOutMethod) -> CoachGuide? {
        switch m {
        case .automatic: return nil
        case .semiAutomatic: return .semiAutomatic
        case .emailOnly, .manual: return .manual
        }
    }
    static var manual: CoachGuide {
        CoachGuide(id: "manual", symbol: "figure.walk", title: Loc.t("How a manual task works"), points: [
            Loc.t("The guide stays at the top of the screen and the site's own page sits below it."),
            Loc.t("It shows one step at a time. Tap Copy to copy your details, paste them into the site, then tap Next step."),
            Loc.t("You handle human checks, phone codes and ID steps yourself. If a page is broken, tap Not working."),
        ])
    }
}

struct CoachGuideSheet: View {
    let guide: CoachGuide
    let done: () -> Void

    var body: some View {
        // The content scrolls and the button is pinned below it, so a long guide never pushes "Got it" off the sheet.
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: guide.symbol).font(.system(size: 48)).foregroundStyle(.tint).padding(.top, 28)
                Text(guide.title).font(.title2.bold()).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(guide.points, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 12)
        }
        // On the scroll view only: set on the whole sheet it was passed down to the button below and replaced its own identifier.
        .accessibilityIdentifier("coach-guide")
        .safeAreaInset(edge: .bottom) {
            Button("Got it", action: done).buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("coach-done")
                .padding(.vertical, 12).frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CoachModifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    let guide: CoachGuide?
    @State private var shown: CoachGuide?

    func body(content: Content) -> some View {
        content
            .onAppear { if shown == nil, let guide, model.shouldCoach(guide.id) { shown = guide } }
            .sheet(item: $shown, onDismiss: nil) { g in
                CoachGuideSheet(guide: g) { model.didCoach(g.id); shown = nil }
                    .interactiveDismissDisabled(false)
                    .onDisappear { model.didCoach(g.id) }
            }
    }
}

extension View {
    /// Shows `guide` once, the first time this screen appears. Pass nil for a screen that needs none.
    func coach(_ guide: CoachGuide?) -> some View { modifier(CoachModifier(guide: guide)) }
}
