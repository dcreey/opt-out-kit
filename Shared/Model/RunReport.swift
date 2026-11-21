import Foundation
import OptOutKitCore

/// What an opt-out run did, in the person's terms: how many went through and which sites need them.
struct RunReport: Identifiable, Equatable {
    let id = UUID()
    let person: String
    let rows: [AppModel.AutoOptOutRow]
    var personID: UUID = UUID()
    /// The sites the run left alone by its own rules, counted by reason (covered by a platform request, sent recently, ...): it never tried them.
    var skipped: [String: Int] = [:]
    var skippedCount: Int { skipped.values.reduce(0, +) }
    /// The commonest reasons first, for the one line that says what was left alone.
    var topSkipReasons: [(String, Int)] { skipped.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map { ($0.key, $0.value) } }

    var sent: Int { rows.filter { if case .submitted = $0.result { return true } else { return false } }.count }
    /// Sites that did not go through and now wait for the person.
    var needYou: [AppModel.AutoOptOutRow] {
        rows.filter { switch $0.result { case .challenged, .needsYou, .needsData, .rejected, .failed: return true; default: return false } }
    }
    /// Sites the run really tried: the ones that were sent plus the ones that did not go through.
    var attempted: Int { sent + needYou.count }
    var allSucceeded: Bool { attempted > 0 && needYou.isEmpty }
}
