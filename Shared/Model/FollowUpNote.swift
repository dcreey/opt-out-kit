import Foundation
import SwiftUI
import OptOutKitCore

/// The words every opt-out flow repeats: finishing an opt-out sometimes takes a follow-up email.
enum FollowUpNote {
    static let text = Loc.t("Some sites will email you afterwards with a link, a code or one more step to finish the opt-out. Watch your inbox, including spam. We will do our best to complete every opt-out inside the app.")
}
