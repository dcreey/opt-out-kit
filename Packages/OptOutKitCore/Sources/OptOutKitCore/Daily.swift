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
    /// The kind of broker each batch is made of (`BrokerCategory` ids, in batch order): every site in a batch is the same kind, so a
    /// day can be "tackle the ad tech brokers".
    public var themes: [String] = []

    public var verifyComplete: Bool { !verify.isEmpty && verifyDone >= verify.count }
    public var emailComplete: Bool { email == nil || emailDone >= (email?.domains.count ?? 0) }
    public var allComplete: Bool { verifyComplete && emailComplete }

    /// - Parameters:
    ///   - queue: the domains of the semi-automated (verify) task, best first.
    ///   - entries: the directory, for each site's id and email address.
    ///   - attempts: every recorded attempt for the person, by entry id.
    ///   - batches: how many batches of 25 the person has asked for today.
    public static func build(queue: [String], entries: [DirectoryEntry], attempts: [String: [OptOutAttempt]], now: Date = Date(),
                             batches: Int = 1, chosen: [String] = [], parked: Set<String> = [], calendar: Calendar = .current) -> DailyGoals {
        let byDomain = Dictionary(entries.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        func emailedDates(_ id: String) -> [Date] { (attempts[id] ?? []).filter { $0.outcome == "emailed" }.map(\.date) }
        func doneBeforeToday(_ id: String, _ dates: [Date]) -> Bool { dates.contains { !calendar.isDate($0, inSameDayAs: now) } }

        // A site finished on an earlier day is behind us; today's list is the next sites, plus anything finished today.
        // A request still holds until it is due to be repeated (6 to 12 months, or never for opt-outs that last): once due, the site is back in the queue.
        // Sites the person set aside (skipped or not working) wait in their own list, so they never hold up the batch.
        let open = queue.compactMap { byDomain[$0] }.filter { e in
            !parked.contains(e.id) &&
            !(doneBeforeToday(e.id, attempts[e.id]?.filter(\.wasSubmitted).map(\.date) ?? []) && e.isCurrent(attempts: attempts, now: now, calendar: calendar))
        }
        // A batch is up to 25 sites of ONE kind. Every day starts fresh: the suggested kind is the highest-ranked one with sites left, unless
        // the person already started work TODAY, in which case it stays on that kind until the batch is done. Sites finished today stay in
        // `open`, so the kind does not change while they work.
        func kind(_ e: DirectoryEntry) -> String { e.about?.category ?? "other" }
        let queued = queue.compactMap { byDomain[$0] }
        let lastDone = queued.compactMap { e -> (Date, DirectoryEntry)? in
            (attempts[e.id] ?? []).filter { $0.wasSubmitted && calendar.isDate($0.date, inSameDayAs: now) }.map(\.date).max().map { ($0, e) }
        }.max { $0.0 < $1.0 }?.1
        // With no kind to carry on from, start with the best-ranked kind that still has sites (see `BrokerCategory.rank`).
        func bestRanked(_ list: [DirectoryEntry]) -> String? {
            Set(list.map(kind)).min { (BrokerCategory(rawValue: $0)?.rank ?? 99, $0) < (BrokerCategory(rawValue: $1)?.rank ?? 99, $1) }
        }
        var remaining = open, todays: [DirectoryEntry] = [], themes: [String] = []
        var theme = lastDone.map(kind)
        for i in 0..<max(1, batches, chosen.count) {
            guard let first = remaining.first else { break }
            // A kind the person chose for this batch wins; otherwise carry on with the last kind, else the first site waiting.
            if i < chosen.count, remaining.contains(where: { kind($0) == chosen[i] }) { theme = chosen[i] }
            else if theme == nil || !remaining.contains(where: { kind($0) == theme }) { theme = bestRanked(remaining) ?? kind(first) }
            let batch = Array(remaining.filter { kind($0) == theme }.prefix(batchSize))
            todays += batch; themes.append(theme!)
            let taken = Set(batch.map(\.id)); remaining.removeAll { taken.contains($0.id) }
        }
        let verifyDone = todays.filter { e in (attempts[e.id] ?? []).contains { $0.wasSubmitted && calendar.isDate($0.date, inSameDayAs: now) } }.count

        // The email covers everything done today, not just the listed batch: a site the person finished any other way (the automatic run,
        // a guide) gets its email too, so every opt-out sent today has a second route behind it.
        let listed = Set(todays.map(\.id))
        let doneElsewhere = entries.filter { e in !listed.contains(e.id) && (attempts[e.id] ?? []).contains { $0.wasSubmitted && calendar.isDate($0.date, inSameDayAs: now) } }
        let withAddress = (todays + doneElsewhere).filter { $0.contactEmail != nil }
        let batch = EmailBatch.single(entries: withAddress, maxRecipients: 1000).first
        let emailedToday = withAddress.filter { e in emailedDates(e.id).contains { calendar.isDate($0, inSameDayAs: now) } }.count
        return DailyGoals(verify: todays.map(\.domain), verifyDone: verifyDone, email: batch, emailDone: emailedToday, batches: max(1, batches, chosen.count), themes: themes)
    }

    /// How many sites still wait in each kind of broker (sites already finished do not count), in the default order. The person picks from these.
    public static func remainingByKind(queue: [String], entries: [DirectoryEntry], attempts: [String: [OptOutAttempt]], parked: Set<String> = [], now: Date = Date(), calendar: Calendar = .current) -> [(kind: String, count: Int)] {
        let byDomain = Dictionary(entries.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        var counts: [String: Int] = [:]
        for d in queue {
            guard let e = byDomain[d], !parked.contains(e.id) else { continue }
            if !e.isCurrent(attempts: attempts, now: now, calendar: calendar) { counts[e.about?.category ?? "other", default: 0] += 1 }
        }
        return counts.map { (kind: $0.key, count: $0.value) }.sorted { (BrokerCategory(rawValue: $0.kind)?.rank ?? 99, $0.kind) < (BrokerCategory(rawValue: $1.kind)?.rank ?? 99, $1.kind) }
    }

    /// Whole days left to finish a queue of `remaining` sites at one batch a day.
    public static func daysLeft(remaining: Int) -> Int { (remaining + batchSize - 1) / batchSize }
}
