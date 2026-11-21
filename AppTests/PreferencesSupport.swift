import Foundation
import OptOutKitCore

/// Tests give the model a `UserDefaults` suite (a throwaway one per test) as its preferences; the app itself uses `StoredPreferences`, rows of its database.
extension UserDefaults: @retroactive Preferences {}
