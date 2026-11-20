import Foundation
import Combine
import OptOutKitCore

// MARK: Pages the runner drives

/// What stands between a prepared form and sending it, which only the person can clear.
enum AssistedBlocker: Equatable { case terms, check(String), certify(String), choose(String) }

/// One site's opt-out page, loaded and filled in, ready to be sent once the person has dealt with any blockers.
@MainActor
protocol AssistedPage: AnyObject {
    func blockers() async -> [AssistedBlocker]
    /// Puts the profile's values back, in case clearing a blocker reloaded the form.
    func refill() async
    func send() async -> SubmitOutcome
    /// What is on screen now, for noticing a confirmation the person caused themselves. Empty in tests.
    func pageText() async -> String
    /// When the page now shows a different privacy form from the one in use (a modal opened, a next step appeared), switches to it and fills it in. True when it did.
    func adoptNewForm() async -> Bool
    /// Scrolls to an opt-out button that appeared out of view. Nothing in tests.
    func scrollToOptOut() async -> Bool
    /// True when the screen changed since the last ask and has settled. Cheap: the page keeps the flag itself.
    func changed() async -> Bool
    /// A page with more than one opt-out form (an email form and a device-ID form side by side): moves on to the next one, filled in and ready. False when none is left.
    func moreForms() async -> Bool
    /// True when the page shows an empty box for a code sent to the person (a verification step); the request is not done until they type it.
    func awaitingCode() async -> Bool
    /// How many times the person pressed a button, link or Enter on the page since it was last filled in; nil where the page cannot tell. Zero means a confirmation that
    /// appears now did not come from them.
    func pressesSinceFill() async -> Int?
    /// True while the person has the cursor in a box (touched or typed lately): the app clicks, scrolls and fills nothing then.
    func userIsTyping() async -> Bool
    /// How many more opt-out forms this page has after the one on screen.
    var formsRemaining: Int { get }
    func close()
    /// Moves the page's web view out of its hidden window so a screen can show it. Called by the runner, never while a view is drawing.
    func present()
}

extension AssistedPage { func scrollToOptOut() async -> Bool { false }; func present() {}; func pageText() async -> String { "" }; func adoptNewForm() async -> Bool { false }; func changed() async -> Bool { false }; func moreForms() async -> Bool { false }; func awaitingCode() async -> Bool { false }; func userIsTyping() async -> Bool { false }; func pressesSinceFill() async -> Int? { nil }; var formsRemaining: Int { 0 } }

@MainActor
protocol AssistedDriver {
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage?
    /// Same, for a form that asks for the address of the person's own listing, which they picked on the site.
    func prepare(_ form: OptOutForm, plan: FillPlan, listingURL: URL?) async -> AssistedPage?
    /// A site with no form the app reads, or one it must not fill: the page is opened and kept open for the person. `fillNothing` puts nothing of theirs in it; otherwise the app
    /// clicks through to a request form when the page hides one behind a button, and fills what it finds. Nil only when the page will not load.
    func prepareHeld(_ form: OptOutForm, plan: FillPlan, fillNothing: Bool) async -> AssistedPage?
    /// The site's search results for the person, to pick their own listing from. Nil when none can be opened.
    func openSearch(_ url: URL) async -> SearchPage?
    /// Why the last `prepare` of this form returned nothing: "noform" when the page loaded but holds no opt-out form we can fill (a contact form, or only an email address), nil when it would not load.
    func failureReason(for form: OptOutForm) -> String?
    /// For a page with no form and no address on file: an address found on the page itself (a privacy@ link), or nil.
    func discoveredEmail(for form: OptOutForm) -> String?
}

extension AssistedDriver {
    func prepareHeld(_ form: OptOutForm, plan: FillPlan, fillNothing: Bool) async -> AssistedPage? { await prepare(form, plan: plan) }
    func failureReason(for form: OptOutForm) -> String? { nil }
    func discoveredEmail(for form: OptOutForm) -> String? { nil }
    func prepare(_ form: OptOutForm, plan: FillPlan, listingURL: URL?) async -> AssistedPage? { await prepare(form, plan: plan) }
    func openSearch(_ url: URL) async -> SearchPage? { nil }
}

/// A site's search results page, shown so the person can tap their own listing.
@MainActor
protocol SearchPage: AnyObject {
    func currentURL() -> URL?
    func close()
}


// MARK: The queue

/// Walks a list of sites one at a time: loads the form, fills it in, waits for the person to clear the human check (or accept
/// terms themselves), then sends it and reads the confirmation. The next site is loaded in the background meanwhile, so the
/// person's only job is the check. It never solves or accepts anything itself.
@MainActor
final class AssistedRunner: ObservableObject {
    /// Asked when a confirmation shows up that the person did not press anything to cause.
    let sentQuestion = SentQuestion()
    struct Item: Identifiable {
        let entry: DirectoryEntry
        let form: OptOutForm
        let plan: FillPlan
        /// The page in English, tried when the translated one has no form we can fill.
        var fallbackForm: OptOutForm?
        /// Set when the form wants the person's own listing: the search results to pick it from.
        var searchURL: URL?
        /// A site with no form at all, only an email address: nothing is loaded, the person is told to send an email instead.
        var emailOnly = false
        /// Sites whose page is a people search with a "Block Profile" button beside each result (USA Trace and its sister site): there is no form to send,
        /// the person searches for themselves in the page and blocks their own listings.
        var blockWidget: Bool { Self.blockWidgetDomains.contains(entry.domain) }
        static let blockWidgetDomains: Set<String> = ["usatrace.com", "quickpeopletrace.com"]
        /// Sites whose only form is a name search: removal is requested on each record's own page, so the person finds their records and files each one.
        var perRecordForm: Bool { Self.perRecordDomains.contains(entry.domain) }
        static let perRecordDomains: Set<String> = ["open-public-records.com"]
        /// What is done on this site's page: a readable form is filled and sent; a page with no readable form (or a form that needs the person) is filled as far as it can be and held;
        /// a page nothing of the person's may go into is only shown. See `PageMode`.
        var mode: PageMode { entry.pageMode }
        /// True when no form of this site is known: the page is opened, it is clicked through to a request form when one hides behind a button, and the person does the rest.
        var noReadableForm: Bool { !entry.hasKnownForm && !emailOnly }
        /// Sites where the app never presses send: the person finishes in the page.
        var handsOff: Bool { blockWidget || perRecordForm || mode != .form }
        var id: String { entry.id }
    }

    enum Phase: Equatable {
        case loading
        case pacing(Int)              // waiting a little before sending to a site of the same company as the last one, so its shared limit is not hit
        case noForm                   // no online form exists for this site: the person sends an email instead (or marks it done, or skips)
        case pickingListing           // the site's search is shown; the person taps their own listing, then confirms it
        case waitingForTerms
        case waitingForCertification
        case waitingForCheck
        case waitingForChoice(String)   // a required menu we could not fill: the person picks, then we go on
        case sending
        case sent(awaitingEmail: Bool)
        case needsMore(String)        // sent, but no confirmation: the site wants another step from the person
        case timedOut
        case manualSend               // the person turned off sending for them: details are filled, they press the page's own button
        case reviewing                // back on a site already passed: shown as it is, nothing is sent for the person
    }

    @Published private(set) var index = 0
    /// Not `@Published`: the run sets its phase on every poll (once a second while it waits), and a screen told "changed" that often redraws its open menu
    /// each time, which showed as a blink. Only a different phase tells the screen.
    private(set) var phase: Phase = .loading { willSet { if newValue != phase { objectWillChange.send() } } }
    @Published private(set) var page: AssistedPage?
    @Published private(set) var finished = false
    @Published private(set) var results: [String: AutoOptOutResult] = [:]
    /// "Is it completely done?", asked when a site looks sent and the page does not say with confidence that nothing more is coming.
    let finishQuestion = FinishQuestion()
    /// True where a person is on screen to answer (Solve and send, Email links); the background run never asks, so it never waits.
    var asksAboutFollowUp = false
    private var followUpAsked = false
    /// The person said (from the … menu) that this site has another email step: whatever is saved for it says so, and nothing more is asked about it.
    private var emailStepFlagged = false
    func flagEmailStep() {
        emailStepFlagged = true; followUpAsked = true; finishQuestion.dismiss()
        // Already saved as sent (the confirmation was noticed): save it again as waiting on an email.
        if let item = current, case .submitted(false)? = results[item.id] { correct(item, to: .submitted(awaitingEmail: true)) }
    }
    /// A short line about something the app did by itself (a new form appeared and was filled), shown under the instruction.
    @Published private(set) var notice: String?
    private var markedDone: AutoOptOutResult?
    /// A site that did not go through (or was reported as not working) and has an email address: the person is asked whether to email it instead.
    @Published private(set) var emailOffer: DirectoryEntry?
    private var emailContinuation: CheckedContinuation<Void, Never>?
    private var reportedNotWorking = false
    /// How many more times the screen is read right away, after a change was seen.
    private var rescans = 0
    /// The page where the person picks their listing, while that step is on.
    @Published private(set) var searchPage: SearchPage?
    /// A line about the previous site, only when it did not go through.
    @Published var previousNote: String?
    /// Counts sites sent, so the screen can show a check each time.
    @Published private(set) var celebrate = 0
    /// Which opt-out form of the page is on screen and how many it has, so the screen can say "form 2 of 3". One form: total 1.
    @Published private(set) var pageForms = (current: 1, total: 1)
    /// The address offered for this site was found on its own page, not on file: the screen says so, so the person checks it before sending.
    @Published private(set) var emailFoundOnPage = false
    /// The site the no-form screen is about, with the address the email goes to: the offer carries an address the page gave (the directory's own entry has none).
    var noFormEntry: DirectoryEntry? { emailOffer ?? current?.entry }
    /// Counts sites that were skipped (by the person, or because their page would not load), so the screen can show it.
    @Published private(set) var skippedCount = 0
    /// A page that would not load within 15 seconds, however many retries: skipped, and set aside for a week.
    static let unloadable = "the page would not load, so it was skipped"
    /// The page loaded but has no opt-out form we can fill (a contact form, or only an email address): skipped, and the email offer is the way through.
    static let noForm = "the site has no online opt-out form we can fill, and we have no email address for it, so it was skipped"
    /// Counts requests sent that now wait on an email, so the screen can explain the email step the first time.
    @Published private(set) var sentAwaitingEmail = 0
    /// Sites whose form could not be read but whose page was opened and held for the person: nothing is ever sent on them.
    private var heldFallback = Set<Int>()
    private enum ListingChoice { case none, mine, notListed }
    private var listingChoice = ListingChoice.none
    /// How often the screen is read for a confirmation the person caused themselves (pressing the page's own button, a message appearing without a new page).
    var watchInterval: TimeInterval = 12

    let items: [Item]
    private let driver: AssistedDriver
    private let onResult: (DirectoryEntry, AutoOptOutResult) -> Void
    private var preparing: [Int: Task<AssistedPage?, Never>] = [:]
    private var loadedPages = Set<Int>()           // pages whose load has finished (well or badly), so a skip does not have to wait for a slow one
    private var skipFlag = false
    private var emailedFlag = false
    /// Auto-send off, and a confirmation the app noticed: the site is recorded and the check is shown, but the screen stays on the site until the person
    /// taps Next site. (With Auto-send on the app moves on by itself, as before.)
    @Published private(set) var awaitingNext = false
    private var recordedEarly = false
    /// The person asked for the previous site: the current one is left as it was, and the one before it opens again.
    private var goBack = false
    /// The furthest site the run has reached. Every site before it that is opened again is only being looked at.
    private var frontier = 0
    /// True while a site already passed is open again.
    @Published private(set) var revisiting = false
    private var autoScrolls = 0          // times the page was scrolled to an opt-out button for this site; the person's own scrolling is never fought
    private var nextContinuation: CheckedContinuation<Void, Never>?
    var waitLimit: TimeInterval = 180
    var pollInterval: TimeInterval = 1
    /// Asked at the moment of sending: whether the app presses the page's own send button. The screen sets it from the person's checkbox.
    var autoSubmit: () -> Bool = { true }
    var pauseAfterSent: TimeInterval = 1.8

    init(items: [Item], driver: AssistedDriver, onResult: @escaping (DirectoryEntry, AutoOptOutResult) -> Void) {
        self.items = items; self.driver = driver; self.onResult = onResult
    }

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var sentCount: Int { results.values.filter { if case .submitted = $0 { return true } else { return false } }.count }

    /// The person says this site is done, in case a confirmation was not noticed. If the page mentions an email to follow, they are asked whether to track it.
    func markDone() async {
        // A confirmation was already noticed and is waiting for the person: Mark as done is their go-ahead, the same as Next site.
        if awaitingNext { resumeNext(); return }
        let text = await page?.pageText() ?? ""
        // Their own tap says it is done; the question is only whether an email still follows. A page that says so with confidence needs no question.
        if FormRun.finishIsCertain(text) || !asksAboutFollowUp && !FormRun.mentionsEmailFollowUp(text) { finishMarked(email: false); return }
        let site = current?.entry.domain ?? ""
        followUpAsked = true
        switch await finishQuestion.ask(site: site, pageSaidEmail: FormRun.mentionsEmailFollowUp(text), allowsNotYet: true) {
        case .done: finishMarked(email: false)
        case .emailFollows, .unsure: finishMarked(email: true)
        case .notYet: break
        }
    }

    /// A send was confirmed with no email step. With a person on screen and a page that does not say it is entirely finished, they are asked; an email step
    /// (or "not sure") makes the result "sent, waiting on an email". Nil: nothing changes.
    private func askAboutFollowUp(_ item: Item, _ outcome: AutoOptOutResult) async -> AutoOptOutResult? {
        guard asksAboutFollowUp, !followUpAsked, !revisiting, case .submitted(false) = outcome else { return nil }
        followUpAsked = true
        let text = await page?.pageText() ?? ""
        if FormRun.finishIsCertain(text) { return nil }
        // Moving on without answering (skip, stop) counts as "not sure": the site waits on an email rather than being counted entirely done.
        var answer = await finishQuestion.ask(site: item.entry.domain, pageSaidEmail: false, allowsNotYet: true)
        // "Not yet": the person stays on the page (nothing moves on) until Next site, Skip or Mark as done; the question then comes once more.
        while answer == .notYet, !skipFlag {
            awaitingNext = true
            await withCheckedContinuation { nextContinuation = $0 }
            awaitingNext = false
            if skipFlag { break }
            answer = await finishQuestion.ask(site: item.entry.domain, pageSaidEmail: false, allowsNotYet: true)
        }
        return answer == .done ? nil : .submitted(awaitingEmail: true)
    }
    /// Saves a changed answer over what was saved when the confirmation was first noticed.
    private func correct(_ item: Item, to result: AutoOptOutResult) {
        results[item.id] = result; sentAwaitingEmail += 1; onResult(item.entry, result)
    }
    private func finishMarked(email: Bool) {
        markedDone = .submitted(awaitingEmail: email)
        phase = .sent(awaitingEmail: email)
        resumeNext()
    }

    /// Reads what is on screen (see `PageFlow.watch`); the outcome when the new text shows a confirmation, nil otherwise. A form that appeared is noted for the screen.
    private func watch(_ page: AssistedPage, baseline: inout String, force: Bool = false, domChanged: Bool = false) async -> AutoOptOutResult? {
        var scrolls = autoScrolls
        let seen = await PageFlow.watch(page, baseline: &baseline, autoScrolls: &scrolls, force: force, domChanged: domChanged, question: sentQuestion)
        autoScrolls = scrolls
        switch seen {
        case .confirmed(let email): return .submitted(awaitingEmail: email)
        case .newFormFilled: notice = Loc.t("A new form appeared and we filled it in. Check it."); return nil
        case .nothing: return nil
        }
    }

    /// "This is my profile": the page the person is on is their listing.
    func confirmListing() {
        guard let url = searchPage?.currentURL(), let search = current?.searchURL, GuidedFlow.isListing(url, searchedAt: search) else {
            notice = Loc.t("Tap your profile in the results first, so the page below is your own, then tap \"This is me\"."); return
        }
        notice = nil; listingChoice = .mine; resumeNext()
    }
    /// "I'm not on this site": nothing is sent.
    func notListed() { listingChoice = .notListed; resumeNext() }

    /// Shows the search for the person and waits until they pick their listing. Nil when they are not listed, skip it, or the search would not open.
    private func chooseListing(_ item: Item, search: URL) async -> (URL?, AutoOptOutResult?) {
        phase = .pickingListing
        listingChoice = .none
        guard let sp = await driver.openSearch(search) else { return (nil, .failed("the search page would not load")) }
        searchPage = sp
        defer { sp.close(); searchPage = nil }
        while true {
            if skipFlag { return (nil, .needsYou("skipped")) }
            switch listingChoice {
            case .mine: if let u = sp.currentURL() { return (u, nil) }
            case .notListed: return (nil, .skippedNotListed)
            case .none: break
            }
            listingChoice = .none
            await withCheckedContinuation { nextContinuation = $0 }
        }
    }

    /// The person emailed a site that had a form: it is done, shown with the green check and counted as emailed, not as skipped.
    func finishByEmail() {
        emailedFlag = true
        skip()
    }

    /// Back to the previous site, to look at it or do something else there. Only works on the second site or later.
    var canGoBack: Bool { index > 0 && !finished && !goingBack }
    /// True from the tap on Previous site until the earlier site's page is on screen: the screen shows the loading mark meanwhile.
    @Published private(set) var goingBack = false
    func back() {
        guard canGoBack else { return }
        goBack = true; skipFlag = true; finishQuestion.dismiss()
        goingBack = true; index -= 1; phase = .loading          // the screen moves to the earlier site at once; its page follows
        resumeNext()
        if emailOffer != nil { emailOffer = nil; emailContinuation?.resume(); emailContinuation = nil }
    }

    func skip(reported: Bool = false) {
        sentQuestion.dismiss(); finishQuestion.dismiss()
        reportedNotWorking = reported; skipFlag = true; resumeNext()
        // Whatever the site was waiting on (the no-form screen, or the offer to email a site that failed), skipping answers it.
        if emailOffer != nil { emailOffer = nil; emailContinuation?.resume(); emailContinuation = nil }
    }

    /// The person answered the offer to email a site that did not go through: `sent` is true once they sent the message, which finishes the site.
    func answerEmailOffer(sent: Bool) {
        // On a site that has no form the person stays here until they send it, mark it done or skip: "No" to the mail prompt is not an answer.
        if !sent, phase == .noForm { return }
        if sent, let entry = emailOffer {
            celebrate += 1
            results[entry.id] = .emailed; previousNote = nil
            onResult(entry, .emailed)          // saved as done, not just shown as done on this screen
        }
        emailOffer = nil
        emailContinuation?.resume(); emailContinuation = nil
    }

    // MARK: Spacing sends to one company's sites

    /// Sites run by one company use one form model (the same field-name prefix, e.g. `InfoPay_...[fname]`) and one rate limit.
    private static func family(_ item: Item) -> String? {
        item.form.fields.compactMap { f -> String? in f.name.firstIndex(of: "[").map { String(f.name[..<$0]) } }.first
    }
    private var lastSend: [String: Date] = [:]
    /// How long to leave between sends to sites of one company.
    var familyGap: TimeInterval = 45
    private func noteSend(_ item: Item) { if let k = Self.family(item) { lastSend[k] = Date() } }
    private func paceIfNeeded(_ item: Item) async {
        guard let k = Self.family(item), let last = lastSend[k] else { return }
        var wait = familyGap - Date().timeIntervalSince(last)
        while wait > 0, !skipFlag, markedDone == nil {
            phase = .pacing(Int(wait.rounded(.up)))
            try? await Task.sleep(nanoseconds: UInt64(min(1, wait) * 1_000_000_000))
            wait = familyGap - Date().timeIntervalSince(last)
        }
    }

    /// A site with no online form and an email address: waits for the person to send the email (finishes the site), mark it done, or skip it.
    private func waitForEmail(_ item: Item) async {
        phase = .noForm; page = nil
        emailOffer = item.entry
        await withCheckedContinuation { emailContinuation = $0 }
        emailOffer = nil
        if skipFlag { record(item, .needsYou("skipped")) }          // sent or marked done was already saved when the person answered
    }

    private func offerEmailIfNeeded(_ item: Item, _ result: AutoOptOutResult) async {
        if !goBack, !revisiting, offersEmail(result, item.entry) {
            emailOffer = item.entry
            await withCheckedContinuation { emailContinuation = $0 }
        }
        reportedNotWorking = false
    }

    private func offersEmail(_ result: AutoOptOutResult, _ entry: DirectoryEntry) -> Bool {
        guard entry.contactEmail != nil else { return false }
        switch result {
        case .failed, .rejected, .challenged: return true
        case .needsYou(let why): return why != "skipped" || reportedNotWorking
        default: return false
        }
    }
    func next() { resumeNext() }
    private func resumeNext() { sentQuestion.dismiss(); nextContinuation?.resume(); nextContinuation = nil }

    private func prepare(_ i: Int) {
        guard items.indices.contains(i), preparing[i] == nil, items[i].searchURL == nil else { return }
        let item = items[i]
        preparing[i] = Task {
            defer { loadedPages.insert(i) }
            if item.noReadableForm || item.mode == .showsOnly { return await driver.prepareHeld(item.form, plan: item.plan, fillNothing: item.mode == .showsOnly) }
            if let page = await driver.prepare(item.form, plan: item.plan) { return page }
            if let fallback = item.fallbackForm { return await driver.prepare(fallback, plan: item.plan) }
            return nil
        }
    }

    func run() async {
        var i = 0
        while items.indices.contains(i) {
            revisiting = i < frontier
            if !revisiting { frontier = i }
            await process(i)
            if goBack {
                // Leaving this site untouched: its page is dropped so it loads fresh when the person gets here again, and the one before it comes back.
                goBack = false
                forget(i)
                forget(i - 1)
                i -= 1
            } else { i += 1 }
        }
        finished = true
    }

    private func forget(_ i: Int) { preparing[i] = nil; loadedPages.remove(i) }

    /// One site, from loading its page to its result. Returns without a result when the person went back.
    private func process(_ i: Int) async {
        do {
            heldFallback.remove(i); index = i; phase = .loading; skipFlag = false; emailedFlag = false; recordedEarly = false; awaitingNext = false; emailFoundOnPage = false; autoScrolls = 0; page = nil; markedDone = nil; followUpAsked = false; emailStepFlagged = false; notice = nil; listingChoice = .none
            if revisiting { notice = Loc.t("You came back to this site. Nothing is sent unless you do it yourself.") }
            if items[i].emailOnly { goingBack = false; await waitForEmail(items[i]); return }
            if let search = items[i].searchURL {
                goingBack = false
                let (listing, early) = await chooseListing(items[i], search: search)
                if let early { record(items[i], early); await offerEmailIfNeeded(items[i], early); return }
                phase = .loading
                preparing[i] = Task { defer { loadedPages.insert(i) }; return await driver.prepare(items[i].form, plan: items[i].plan, listingURL: listing) }
            } else { prepare(i) }
            // Skip works while a page is still loading: wait for the load, but not past the person's skip.
            while !loadedPages.contains(i), !skipFlag { try? await Task.sleep(nanoseconds: UInt64(min(pollInterval, 0.1) * 1_000_000_000)) }
            if !loadedPages.contains(i), skipFlag {
                let loading = preparing[i]
                Task { await loading?.value?.close() }          // the page that was loading is closed when it arrives
                record(items[i], .needsYou("skipped"))
                await offerEmailIfNeeded(items[i], .needsYou("skipped"))
                return
            }
            var firstTry = await preparing[i]?.value
            // A page that loaded but whose form we cannot read, with no address to write to: opened and held for the person (filled as far as possible, never sent) rather than skipped.
            if firstTry == nil, driver.failureReason(for: items[i].form) == "noform", items[i].entry.contactEmail == nil, driver.discoveredEmail(for: items[i].form) == nil,
               let held = await driver.prepareHeld(items[i].form, plan: items[i].plan, fillNothing: items[i].mode == .showsOnly) {
                firstTry = held; heldFallback.insert(i)
            }
            guard let ready = firstTry else {
                goingBack = false
                let noForm = driver.failureReason(for: items[i].form) == "noform"
                // The page loaded but holds no form we can fill, and the site gives an address: say so, and let the person send the email from here.
                if noForm, items[i].entry.contactEmail != nil { await waitForEmail(items[i]); return }
                // No address on file, but the page itself gives one: the person is offered that, told where it came from.
                if noForm, let found = driver.discoveredEmail(for: items[i].form) {
                    var entry = items[i].entry; entry.contactEmail = found
                    emailFoundOnPage = true
                    await waitForEmail(AssistedRunner.Item(entry: entry, form: items[i].form, plan: items[i].plan)); return
                }
                let why = noForm ? Self.noForm : Self.unloadable
                record(items[i], .needsYou(why))
                await offerEmailIfNeeded(items[i], .needsYou(why))
                return
            }
            ready.present()         // here, not while the screen is drawing: moving a web view during a draw crashed the app
            page = ready; goingBack = false
            pageForms = (1, 1 + ready.formsRemaining)
            prepare(i + 1)      // load the next one while the person works on this one

            var outcome: AutoOptOutResult?
            var sentForms = 0, sentEmail = false, forceManual = false
            var attempts = 0
            var baseline = await ready.pageText()
            while outcome == nil, attempts < 3 {
                attempts += 1
                var waited: TimeInterval = 0, sinceWatch: TimeInterval = 0
                while true {
                    if skipFlag { outcome = .needsYou("skipped"); break }
                    if let done = markedDone { outcome = done; break }
                    let blockers = revisiting || forceManual ? [] : await ready.blockers()        // a site visited again is never sent for the person
                    if blockers.isEmpty { break }
                    if blockers.contains(.terms) { phase = .waitingForTerms }
                    else if blockers.contains(where: { if case .certify = $0 { return true } else { return false } }) { phase = .waitingForCertification }
                    else if let pick = blockers.compactMap({ if case .choose(let what) = $0 { return what } else { return nil } }).first { phase = .waitingForChoice(pick) }
                    else { phase = .waitingForCheck }
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    waited += pollInterval; sinceWatch += pollInterval
                    // The page says when it changed (checked every poll); the slow read is only a backup for changes it cannot see.
                    let moved = await ready.changed()
                    if moved { rescans = 3 }
                    let force = rescans > 0; if force { rescans -= 1 }
                    if moved || force || sinceWatch >= watchInterval {
                        sinceWatch = 0
                        if let hit = await watch(ready, baseline: &baseline, force: force, domChanged: moved) {
                            outcome = hit
                            if case .submitted(let email) = hit {
                                phase = .sent(awaitingEmail: email)
                                if !autoSubmit() {
                                    holdAfterDetected(items[i], hit)
                                    await withCheckedContinuation { nextContinuation = $0 }      // until Next site (or Skip, Previous, Mark as done)
                                    awaitingNext = false
                                }
                            }
                            break
                        }
                    }
                    if waited > waitLimit { phase = .timedOut; outcome = .needsYou("timed out waiting for the check"); break }
                }
                if outcome != nil { break }
                // Sites run by one company share one limit on how fast requests may come: space the sends so the later ones are not turned away.
                if !revisiting { await paceIfNeeded(items[i]) }
                if skipFlag { outcome = .needsYou("skipped"); break }
                if let done = markedDone { outcome = done; break }
                phase = .sending
                await ready.refill()
                if !revisiting { noteSend(items[i]) }
            // A "Block Profile" page has no form of ours to send (pressing its "Start" would only run another search): the person blocks their own listings.
            let manual = !revisiting && !items[i].handsOff && !heldFallback.contains(i) && (!autoSubmit() || forceManual)
            let step: SendStep = items[i].handsOff || heldFallback.contains(i) || revisiting || manual ? .notConfirmed(.failed("waiting for you to finish in the page")) : await PageFlow.sendOnce(ready)
            switch step {
                case .sent(let email, let more):
                    sentForms += 1; sentEmail = sentEmail || email
                    // The same page may hold another opt-out form (a device ID, a second request type): it gets its turn before the site is done.
                    if more { pageForms.current += 1; phase = .loading; attempts = 0; continue }
                    phase = .sent(awaitingEmail: sentEmail); outcome = .submitted(awaitingEmail: sentEmail)
                case .handToPerson:
                    // A human check that refuses a scripted press (reCAPTCHA v3) is not retried: the person presses the page's own button, and we notice the result.
                    forceManual = true; notice = Loc.t("The site's human check did not accept an automatic send. Press its Submit button yourself.")
                    continue
                case .nextStep, .checkAppeared:
                    continue      // a check appeared after sending (or the next step of the form came up): go round again
                case .notConfirmed(let answer):
                    let why: String = { switch answer { case .rejected(let w), .failed(let w), .challenged(let w): return w; default: return "no confirmation" } }()
                    phase = revisiting ? .reviewing : manual ? .manualSend : .needsMore(why)
                    // A site the person is sending themselves is not failed when they move on without a confirmation: it just is not done yet.
                    // One form of the page went through and a later one did not: the site is sent, and the person can finish the rest in the page.
                    outcome = sentForms > 0 ? .submitted(awaitingEmail: sentEmail) : why == AutoOptOut.rateLimited || manual ? .needsYou(manual ? "you sent it yourself and we saw no confirmation" : why) : .failed(why)         // a rate limit is not the form's fault
                    // The person finishes this one, then taps Next or Mark as done; meanwhile the screen is read every few seconds in case a confirmation appears.
                    var watched = await ready.pageText()
                    let watcher = Task { @MainActor [weak self] in
                        var idle: TimeInterval = 0
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 1) * 1_000_000_000))
                            guard !Task.isCancelled, let self else { return }
                            idle += self.pollInterval
                            let moved = await ready.changed()
                            if moved { self.rescans = 3 }
                            let force = self.rescans > 0; if force { self.rescans -= 1 }
                            guard moved || force || idle >= self.watchInterval else { continue }
                            idle = 0
                            if let hit = await self.watch(ready, baseline: &watched, force: force, domChanged: moved) {
                                self.markedDone = hit
                                if case .submitted(let email) = hit {
                                    self.phase = .sent(awaitingEmail: email)
                                    // One rule: Auto-send on moves on by itself, off waits for the person's Next site. The confirmation is noticed and saved either way.
                                    if self.autoSubmit() { self.resumeNext() } else { self.holdAfterDetected(self.items[i], hit) }
                                } else { self.resumeNext() }
                                return
                            }
                        }
                    }
                    await withCheckedContinuation { nextContinuation = $0 }
                    watcher.cancel(); awaitingNext = false
                    if let done = markedDone { outcome = done }
                case .dryRun: outcome = .dryRunReady
                }
            }
            var final = outcome ?? .challenged("the check came back")
            // The person emailed the site while its form was failing or waiting on them: that is the answer, not another failure to offer an email for.
            if emailedFlag { if case .submitted = final {} else { final = .needsYou("skipped") } }
            if recordedEarly {
                // Saved when the confirmation was noticed; the question comes now, with the confirmation still on screen, and a changed answer is saved over it.
                if let asked = await askAboutFollowUp(items[i], final) { final = asked; correct(items[i], to: asked) }
            } else {
                if let asked = await askAboutFollowUp(items[i], final) { final = asked }
                record(items[i], final)
                await offerEmailIfNeeded(items[i], final)
                // The sent check is on screen meanwhile; the page it came from stays under it for a moment.
                if case .submitted? = outcome { try? await Task.sleep(nanoseconds: UInt64(pauseAfterSent * 1_000_000_000)) }
            }
            ready.close(); page = nil
        }
    }

    /// A confirmation was noticed: save and celebrate it now, and wait for the person's Next site.
    private func holdAfterDetected(_ item: Item, _ hit: AutoOptOutResult) {
        record(item, hit); recordedEarly = true; awaitingNext = true
    }

    private func record(_ item: Item, _ result: AutoOptOutResult) {
        var result = result
        if goBack { return }                      // leaving a site by going back says nothing about it
        if revisiting {
            // A site visited again keeps what it had, unless the person finished it now (a skipped site they decide to do after all).
            switch result { case .submitted, .emailed: break; default: return }
        }
        if emailedFlag, case .needsYou("skipped") = result { result = .emailed; celebrate += 1; emailedFlag = false }
        if emailStepFlagged, case .submitted(false) = result { result = .submitted(awaitingEmail: true) }
        results[item.id] = result
        switch result {
        case .submitted(let email): celebrate += 1; previousNote = nil; if email { sentAwaitingEmail += 1 }
        case .failed(let why), .rejected(let why), .challenged(let why):
            previousNote = Loc.f("%@ was not sent: %@.", item.entry.domain, why)
        case .needsYou(let why) where why != "skipped": previousNote = Loc.f("%@ was not sent: %@.", item.entry.domain, why); if why == Self.unloadable || why == Self.noForm { skippedCount += 1 }
        default: previousNote = nil
        }
        if case .needsYou("skipped") = result { skippedCount += 1 }
        onResult(item.entry, result)
    }
}
