import Foundation

/// The app's Loc reads its translations from the app bundle; on the Mac the English key is the text.
enum Loc {
    static func t(_ key: String) -> String { key }
    static func f(_ key: String, _ args: CVarArg...) -> String { String(format: key.replacingOccurrences(of: "%@", with: "%@"), arguments: args) }
}
