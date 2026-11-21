import Foundation
import OptOutKitCore
import Yams

public extension TermsLibrary {
    static func load(_ url: URL) throws -> TermsLibrary {
        try YAMLDecoder().decode(TermsLibrary.self, from: String(contentsOf: url, encoding: .utf8))
    }
}
