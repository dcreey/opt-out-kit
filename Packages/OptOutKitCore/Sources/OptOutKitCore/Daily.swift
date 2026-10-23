import Foundation

/// Today's goals. Every day has the same shape: finish a batch of semi-automated sites (fill in and tick the human check), then email the
/// same batch as a safety net. Batches advance by themselves as sites are finished, so about a month covers every site, and a person who
/// wants to go faster can take another batch.
public struct DailyGoals: Equatable, Sendable {
    public static let batchSize = 25

    /// The sites to verify today, in queue order. Sites finished on an earlier day are not in it; ones finished today stay, so the list
    /// does not shift under the person while they work.
    public var verify: [String]
    public var verifyDone: Int
    /// The same sites' email addresses, one message (every address in Bcc), and how many of those sites were emailed today.
    public var email: EmailBatch?
    public var emailDone: Int
    /// How many batches have been taken today (1 = the normal 25).
    public var batches: Int

    public var verifyComplete: Bool { !verify.isEmpty && verifyDone >= verify.count }
    public var emailComplete: Bool { email == nil || emailDone >= (email?.domains.count ?? 0) }
    public var allComplete: Bool { verifyComplete && emailComplete }

    /// - Parameters:
    ///   - queue: the domains of the semi-automated (verify) task, best first.
    ///   - entries: the directory, for each site's id and email address.
    ///   - attempts: every recorded attempt for the person, by entry id.
    ///   - batches: how many batches of 25 the person has asked for today.
    public static func build(queue: [String], entries: [DirectoryEntry], attempts: [String: [OptOutAttempt]], now: Date = Date(),
                             batches: Int = 1, calendar: Calendar = .current) -> DailyGoals {
        let byDomain = Dictionary(entries.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        func emailedDates(_ id: String) -> [Date] { (attempts[id] ?? []).filter { $0.outcome == "emailed" }.map(\.date) }
        func doneBeforeToday(_ id: String, _ dates: [Date]) -> Bool { dates.contains { !calendar.isDate($0, inSameDayAs: now) } }

        // A site finished on an earlier day is behind us; today's list is the next sites, plus anything finished today.
        let open = queue.compactMap { byDomain[$0] }.filter { e in
            !doneBeforeToday(e.id, attempts[e.id]?.filter(\.wasSubmitted).map(\.date) ?? [])
        }
        let todays = Array(open.prefix(batchSize * max(1, batches)))
        let verifyDone = todays.filter { e in (attempts[e.id] ?? []).contains { $0.wasSubmitted && calendar.isDate($0.date, inSameDayAs: now) } }.count

        let withAddress = todays.filter { $0.contactEmail != nil }
        let batch = EmailBatch.single(entries: withAddress, maxRecipients: 1000).first
        let emailedToday = withAddress.filter { e in emailedDates(e.id).contains { calendar.isDate($0, inSameDayAs: now) } }.count
        return DailyGoals(verify: todays.map(\.domain), verifyDone: verifyDone, email: batch, emailDone: emailedToday, batches: max(1, batches))
    }

    /// Whole days left to finish a queue of `remaining` sites at one batch a day.
    public static func daysLeft(remaining: Int) -> Int { (remaining + batchSize - 1) / batchSize }
}
