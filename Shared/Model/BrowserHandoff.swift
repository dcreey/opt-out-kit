import Foundation
import Combine

/// "Open in my browser" from a guide's … menu: the page goes to the phone's default browser, and the question "Did you complete it?" is already waiting when the
/// person comes back, as with another mail app. Yes finishes the site the way that flow finishes one; No changes nothing and the guide stays where it was.
@MainActor
final class BrowserHandoff: ObservableObject {
    @Published var asking = false
    func open(_ url: URL, launch: (URL) -> Void) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        asking = true
        launch(url)
    }
    func answer(completed: Bool, finish: () -> Void) { asking = false; if completed { finish() } }
}
