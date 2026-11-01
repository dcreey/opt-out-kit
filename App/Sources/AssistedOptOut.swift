import SwiftUI
import MessageUI
import WebKit
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
    func close()
    /// The live web view to show the person, or nil in tests. Reading it changes nothing: `present()` must be called first.
    var webView: WKWebView? { get }
    /// Moves the page's web view out of its hidden window so a screen can show it. Called by the runner, never while a view is drawing.
    func present()
}

extension AssistedPage { func scrollToOptOut() async -> Bool { false }; func present() {}; func pageText() async -> String { "" }; func adoptNewForm() async -> Bool { false }; func changed() async -> Bool { false } }

@MainActor
protocol AssistedDriver {
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage?
    /// Same, for a form that asks for the address of the person's own listing, which they picked on the site.
    func prepare(_ form: OptOutForm, plan: FillPlan, listingURL: URL?) async -> AssistedPage?
    /// The site's search results for the person, to pick their own listing from. Nil when none can be opened.
    func openSearch(_ url: URL) async -> SearchPage?
    /// Why the last `prepare` of this form returned nothing: "noform" when the page loaded but holds no opt-out form we can fill (a contact form, or only an email address), nil when it would not load.
    func failureReason(for form: OptOutForm) -> String?
}

extension AssistedDriver {
    func failureReason(for form: OptOutForm) -> String? { nil }
    func prepare(_ form: OptOutForm, plan: FillPlan, listingURL: URL?) async -> AssistedPage? { await prepare(form, plan: plan) }
    func openSearch(_ url: URL) async -> SearchPage? { nil }
}

/// A site's search results page, shown so the person can tap their own listing.
@MainActor
protocol SearchPage: AnyObject {
    var webView: WKWebView? { get }
    func currentURL() -> URL?
    func close()
}

@MainActor
final class WebSearchPage: SearchPage {
    private let session: WebViewSession
    private(set) var webView: WKWebView?
    init(session: WebViewSession) { self.session = session; webView = session.presentable() }
    func currentURL() -> URL? { session.webView.url }
    func close() { session.close() }
}

/// The real thing: a web view the person can see and use for the one step only they can do.
@MainActor
struct WebAssistedDriver: AssistedDriver {
    /// Test hook: render this HTML instead of loading the site, so a test can imitate a form and a bot check.
    var htmlOverride: String?
    private static var reasons: [String: String] = [:]
    func failureReason(for form: OptOutForm) -> String? { Self.reasons[form.page.absoluteString] }
    /// When set, the form is found on the live page and filled from these details (the stored crawl is only a hint).
    var person: Person?
    var advertisingID: String?

    /// What a form looks like, to tell one from another when the page changes under the person.
    static func signature(_ form: LiveForm) -> String { form.fields.filter(\.visible).map { $0.label + "/" + $0.type }.joined(separator: "|") }

    func openSearch(_ url: URL) async -> SearchPage? {
        let session = WebViewSession.make()
        do { try await session.load(URLRequest(url: url)) } catch { session.close(); return nil }
        await session.settlePage(maxWait: 8)
        _ = await session.denyCookies()
        await session.hideConsentOverlays()
        return WebSearchPage(session: session)
    }

    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { await prepare(form, plan: plan, listingURL: nil) }

    func prepare(_ form: OptOutForm, plan: FillPlan, listingURL: URL?) async -> AssistedPage? {
        let session = WebViewSession.make()
        Self.reasons[form.page.absoluteString] = nil
        do {
            if let htmlOverride { try await session.loadHTML(htmlOverride) } else { try await session.load(URLRequest(url: form.page), within: 15) }
        } catch { NSLog("OOK load failed %@: %@", form.page.absoluteString, "\(error)"); session.close(); return nil }
        await session.settlePage(maxWait: 10)
        _ = await session.denyCookies()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = await session.denyCookies()
        await session.hideConsentOverlays()
        let page = WebAssistedPage(session: session, plan: plan)
        if let person {
            _ = await session.advanceToRequestForm()
            if await session.chooseNameTab() { try? await Task.sleep(nanoseconds: 600_000_000) }
            let found = await session.discoverFormsDeep()
            guard let live = LiveFormPicker.pick(found, pageContext: await session.pageContext()) else {
                Self.reasons[form.page.absoluteString] = "noform"
                NSLog("OOK no form %@: %@", form.page.absoluteString, found.map { "[\($0.fields.filter(\.visible).map(\.label).joined(separator: ",")) | \($0.buttons.joined(separator: ","))]" }.joined(separator: " "))
                session.close(); return nil
            }
            // Only a form that asks for the phone's advertising ID makes the app ask the person (once) for permission to read it.
            let liveForm = live.asOptOutForm(page: form.page)
            var adID = advertisingID
            if adID == nil, AdvertisingID.isAsked(by: liveForm.fields) { adID = await AdvertisingID.current() }
            let livePlan = FormFiller.plan(for: liveForm, signals: nil, person: person, listingURL: listingURL, advertisingID: adID)
            // Whatever the plan says the person must do (tick a consent box, type a missing detail), the page is shown with everything else filled in:
            // the runner waits for them at that step. Closing the page here made such sites look like they "would not load".
            page.useLive(form: live.token, plan: livePlan, ownerMayConfirm: person.mayConfirmOwnIdentity(), stateName: USStates.name(for: person.currentAddress?.state ?? ""))
            if case .ready = livePlan.verdict {} else { NSLog("OOK plan needs the person %@: %@", form.page.absoluteString, "\(livePlan.verdict)") }
            page.remember(person: person, advertisingID: adID, listingURL: listingURL, page: form.page, signature: Self.signature(live))
        }
        await page.refill()
        if let token = page.currentFormToken { await session.scrollFormIntoView(token: token) }
        await session.scrollChallengeIntoView()
        return page
    }
}

@MainActor
final class WebAssistedPage: AssistedPage {
    private let session: WebViewSession
    private var plan: FillPlan
    private var liveForm: String?
    private var ownerMayConfirm = false
    private var stateName: String?
    private var person: Person?
    private var advertisingID: String?
    private var listingURL: URL?
    private var pageURL: URL?
    private var knownSignatures = Set<String>()
    private var shown: WKWebView?
    var currentFormToken: String? { liveForm }

    init(session: WebViewSession, plan: FillPlan) { self.session = session; self.plan = plan }

    func useLive(form token: String, plan: FillPlan, ownerMayConfirm: Bool, stateName: String? = nil) { liveForm = token; self.plan = plan; self.ownerMayConfirm = ownerMayConfirm; self.stateName = stateName }

    func remember(person: Person, advertisingID: String?, listingURL: URL? = nil, page: URL, signature: String) { self.listingURL = listingURL; self.person = person; self.advertisingID = advertisingID; pageURL = page; knownSignatures = [signature] }

    func adoptNewForm() async -> Bool {
        guard let person, let pageURL, liveForm != nil else { return false }
        let frameBefore = session.activeFrame
        let forms = await session.discoverForms(waitForFrames: false)
        // A form not seen before wins over the one already filled in: choosing "remove my information" opens a second form beside the first.
        let context = await session.pageContext()
        let fresh = forms.filter { LiveFormPicker.score($0, pageContext: context) >= 3 && !knownSignatures.contains(WebAssistedDriver.signature($0)) }
            .max { LiveFormPicker.score($0, pageContext: context) < LiveFormPicker.score($1, pageContext: context) }
        guard let new = fresh ?? LiveFormPicker.pick(forms, pageContext: context) else { session.activeFrame = frameBefore; return false }
        let sig = WebAssistedDriver.signature(new)
        if knownSignatures.contains(sig) { liveForm = new.token; return false }       // the same form, with its marks put on again
        let form = new.asOptOutForm(page: pageURL)
        let livePlan = FormFiller.plan(for: form, signals: nil, person: person, listingURL: listingURL, advertisingID: advertisingID)
        // A detail the profile lacks (a birth date) is left for the person to type; what the profile has is still filled in.
        switch livePlan.verdict {
        case .ready, .needsData: break
        case .needsYou: session.activeFrame = frameBefore; return false
        }
        liveForm = new.token; plan = livePlan; knownSignatures.insert(sig)
        // What the person already typed is kept; only empty boxes of the new form are filled.
        _ = await session.fillLive(plan.values, keepExisting: true)
        _ = await session.chooseRequestOptions(form: new.token, ownerMayConfirm: ownerMayConfirm)
        _ = await session.chooseCustomMenus(state: stateName)
        _ = await session.chooseTileButtons()
        return true
    }

    var webView: WKWebView? { shown }
    func present() { if shown == nil { shown = session.presentable() } }

    func blockers() async -> [AssistedBlocker] {
        var out: [AssistedBlocker] = []
        if await session.hasTermsPrompt() { out.append(.terms) }
        if let text = await session.pendingCertification() { out.append(.certify(text)) }
        if let why = await session.visibleChallenge() { out.append(.check(why)) }
        if await session.emptyCodeField() { out.append(.check("a code to type")) }
        // A required menu or box the app had no value for (a state list that does not offer the person's state, a request type): the person picks.
        if let liveForm, let what = await session.emptyRequiredChoice(form: liveForm) { out.append(.choose(what)) }
        return out
    }

    func refill() async {
        if let liveForm {
            _ = await session.fillLive(plan.values)
            let options = await session.chooseRequestOptions(form: liveForm, ownerMayConfirm: ownerMayConfirm)
            _ = await session.chooseCustomMenus(state: stateName)
            _ = await session.chooseTileButtons()
            // Choosing "remove my information" can reveal more boxes (state, birth year): read the form again and fill those too.
            if options.chosen > 0 { _ = await adoptNewForm() }
        } else { _ = await session.fillFields(plan.values) }
    }

    func send() async -> SubmitOutcome {
        #if DEBUG
        // Simulator work: `-assisted-no-send` watches a real page without ever pressing its submit button.
        if ProcessInfo.processInfo.arguments.contains("-assisted-no-send") { return .filledNotSubmitted }
        #endif
        let before = await session.visibleText()
        let pressed: Bool
        if let liveForm { pressed = await session.pressLiveSubmit(form: liveForm) } else { pressed = await session.pressSubmit(for: plan.values) }
        guard pressed else { return .failed("no submit button found") }
        await session.settlePage(maxWait: 20)
        if await session.pressConfirmStep() { await session.settlePage(maxWait: 20) }
        if let why = await session.visibleChallenge() { return .challenged(why) }
        return WebFormSubmitter.classifyAfterSending(before: before, after: await session.visibleText())
    }

    func pageText() async -> String { await session.viewportText() }
    func changed() async -> Bool { await session.pageChanged() }
    func scrollToOptOut() async -> Bool { await session.scrollToOptOutControl() }

    func close() { session.close() }
}

// MARK: The queue

/// Walks a list of sites one at a time: loads the form, fills it in, waits for the person to clear the bot check (or accept
/// terms themselves), then sends it and reads the confirmation. The next site is loaded in the background meanwhile, so the
/// person's only job is the check. It never solves or accepts anything itself.
@MainActor
final class AssistedRunner: ObservableObject {
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
        /// Sites where the app never presses send: the person finishes in the page.
        var handsOff: Bool { blockWidget || perRecordForm }
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
    }

    @Published private(set) var index = 0
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var page: AssistedPage?
    @Published private(set) var finished = false
    @Published private(set) var results: [String: AutoOptOutResult] = [:]
    /// True while the person is asked whether the page's email step should be tracked, after they tapped Mark as done.
    @Published var askFollowUp = false
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
    /// Counts sites that were skipped (by the person, or because their page would not load), so the screen can show it.
    @Published private(set) var skippedCount = 0
    /// A page that would not load within 15 seconds, however many retries: skipped, and set aside for a week.
    static let unloadable = "the page would not load, so it was skipped"
    /// The page loaded but has no opt-out form we can fill (a contact form, or only an email address): skipped, and the email offer is the way through.
    static let noForm = "the site has no online opt-out form we can fill (its page is a contact form or only gives an email address), so it was skipped"
    /// Counts requests sent that now wait on an email, so the screen can explain the email step the first time.
    @Published private(set) var sentAwaitingEmail = 0
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
    private var autoScrolls = 0          // times the page was scrolled to an opt-out button for this site; the person's own scrolling is never fought
    private var nextContinuation: CheckedContinuation<Void, Never>?
    var waitLimit: TimeInterval = 180
    var pollInterval: TimeInterval = 1
    var pauseAfterSent: TimeInterval = 1.8

    init(items: [Item], driver: AssistedDriver, onResult: @escaping (DirectoryEntry, AutoOptOutResult) -> Void) {
        self.items = items; self.driver = driver; self.onResult = onResult
    }

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var sentCount: Int { results.values.filter { if case .submitted = $0 { return true } else { return false } }.count }

    /// The person says this site is done, in case a confirmation was not noticed. If the page mentions an email to follow, they are asked whether to track it.
    func markDone() async {
        let text = await page?.pageText() ?? ""
        if FormRun.mentionsEmailFollowUp(text) { askFollowUp = true } else { finishMarked(email: false) }
    }
    func answerFollowUp(track: Bool) { askFollowUp = false; finishMarked(email: track) }
    private func finishMarked(email: Bool) {
        markedDone = .submitted(awaitingEmail: email)
        phase = .sent(awaitingEmail: email)
        resumeNext()
    }

    /// Reads what is on screen; true outcome when the new text shows a confirmation, nil when nothing changed or it says nothing of the kind.
    private func watch(_ page: AssistedPage, baseline: inout String, force: Bool = false, domChanged: Bool = false) async -> AutoOptOutResult? {
        let now = await page.pageText()
        // A form that opens with an animation may still be collapsed on the first look, so after a change the page is read again a few times even when the text is the same.
        guard !now.isEmpty, now != baseline || force else { return nil }
        let added = FormRun.newText(before: baseline, after: now)
        baseline = now
        if case .submitted(let email) = FormRun.classifyConfirmed(added) { return .submitted(awaitingEmail: email) }
        // Nothing confirmed, but the screen changed: a new privacy form may have appeared (a window opened, the next step). Fill it in if so.
        if await page.adoptNewForm() { notice = Loc.t("A new form appeared and we filled it in. Check it."); NSLog("OOKSCROLL adoptNewForm filled a new form") }
        // Only a change in the page itself brings the opt-out button into view. The words on screen also change when the person scrolls, and moving the page
        // under them because the new words mention "opt out" is the page jumping about; so at most twice per site, and never for a scroll.
        else if domChanged, autoScrolls < 2, FormRun.mentionsOptOutControl(added) { if await page.scrollToOptOut() { autoScrolls += 1 } }
        return nil
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

    func skip(reported: Bool = false) {
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
        if offersEmail(result, item.entry) {
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
    private func resumeNext() { nextContinuation?.resume(); nextContinuation = nil }

    private func prepare(_ i: Int) {
        guard items.indices.contains(i), preparing[i] == nil, items[i].searchURL == nil else { return }
        let item = items[i]
        preparing[i] = Task {
            defer { loadedPages.insert(i) }
            if let page = await driver.prepare(item.form, plan: item.plan) { return page }
            if let fallback = item.fallbackForm { return await driver.prepare(fallback, plan: item.plan) }
            return nil
        }
    }

    func run() async {
        for i in items.indices {
            index = i; phase = .loading; skipFlag = false; emailedFlag = false; autoScrolls = 0; page = nil; markedDone = nil; askFollowUp = false; notice = nil; listingChoice = .none
            if items[i].emailOnly { await waitForEmail(items[i]); continue }
            if let search = items[i].searchURL {
                let (listing, early) = await chooseListing(items[i], search: search)
                if let early { record(items[i], early); await offerEmailIfNeeded(items[i], early); continue }
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
                continue
            }
            guard let ready = await preparing[i]?.value else {
                let noForm = driver.failureReason(for: items[i].form) == "noform"
                // The page loaded but holds no form we can fill, and the site gives an address: say so, and let the person send the email from here.
                if noForm, items[i].entry.contactEmail != nil { await waitForEmail(items[i]); continue }
                let why = noForm ? Self.noForm : Self.unloadable
                record(items[i], .needsYou(why))
                await offerEmailIfNeeded(items[i], .needsYou(why))
                continue
            }
            ready.present()         // here, not while the screen is drawing: moving a web view during a draw crashed the app
            page = ready
            prepare(i + 1)      // load the next one while the person works on this one

            var outcome: AutoOptOutResult?
            var attempts = 0
            var baseline = await ready.pageText()
            while outcome == nil, attempts < 3 {
                attempts += 1
                var waited: TimeInterval = 0, sinceWatch: TimeInterval = 0
                while true {
                    if skipFlag { outcome = .needsYou("skipped"); break }
                    if let done = markedDone { outcome = done; break }
                    let blockers = await ready.blockers()
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
                            if case .submitted(let email) = hit { phase = .sent(awaitingEmail: email) }
                            break
                        }
                    }
                    if waited > waitLimit { phase = .timedOut; outcome = .needsYou("timed out waiting for the check"); break }
                }
                if outcome != nil { break }
                // Sites run by one company share one limit on how fast requests may come: space the sends so the later ones are not turned away.
                await paceIfNeeded(items[i])
                if skipFlag { outcome = .needsYou("skipped"); break }
                if let done = markedDone { outcome = done; break }
                phase = .sending
                await ready.refill()
                noteSend(items[i])
            // A "Block Profile" page has no form of ours to send (pressing its "Start" would only run another search): the person blocks their own listings.
            switch items[i].handsOff ? SubmitOutcome.failed("waiting for you to finish in the page") : await ready.send() {
                case .submitted(let email):
                    phase = .sent(awaitingEmail: email); outcome = .submitted(awaitingEmail: email)
                case .challenged: continue      // a check appeared after sending: wait for the person again
                case .rejected(let why), .failed(let why):
                    phase = .needsMore(why)
                    outcome = why == AutoOptOut.rateLimited ? .needsYou(why) : .failed(why)         // a rate limit is not the form's fault
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
                                if case .submitted(let email) = hit { self.phase = .sent(awaitingEmail: email) }
                                self.resumeNext(); return
                            }
                        }
                    }
                    await withCheckedContinuation { nextContinuation = $0 }
                    watcher.cancel()
                    if let done = markedDone { outcome = done }
                case .filledNotSubmitted: outcome = .dryRunReady
                }
            }
            let final = outcome ?? .challenged("the check came back")
            record(items[i], final)
            await offerEmailIfNeeded(items[i], final)
            // The sent check is on screen meanwhile; the page it came from stays under it for a moment.
            if case .submitted? = outcome { try? await Task.sleep(nanoseconds: UInt64(pauseAfterSent * 1_000_000_000)) }
            ready.close(); page = nil
        }
        finished = true
    }

    private func record(_ item: Item, _ result: AutoOptOutResult) {
        var result = result
        if emailedFlag, case .needsYou("skipped") = result { result = .emailed; celebrate += 1; emailedFlag = false }
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

// MARK: Screen

/// Hosts the live web view so the person can solve the check in it.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct AssistedOptOutView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject var runner: AssistedRunner
    @State private var showSent = false
    @State private var showSkipped = false
    @StateObject private var handoff: EmailHandoff
    init(runner: AssistedRunner) { _runner = StateObject(wrappedValue: runner); _handoff = StateObject(wrappedValue: EmailHandoff(runner: runner)) }
    @State private var explainAdID: (batch: EmailBatch, name: String)?
    @State private var explainEmail = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if runner.finished { summary } else { working }
            }
            .navigationBarHidden(!runner.finished)
            .navigationTitle("Solve and send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .alert("This page mentions an email", isPresented: Binding(get: { runner.askFollowUp }, set: { _ in })) {
            Button("Yes, track it") { runner.answerFollowUp(track: true) }
            Button("No, it is done") { runner.answerFollowUp(track: false) }
        } message: { Text("A confirmation or verification email looks like it is coming. Track it, and the app reminds you to finish it in Email links?") }
        .task { await runner.run() }
        .overlay { if showSent { SentCheck().transition(.opacity) } else if showSkipped { SkippedMark().transition(.opacity) } }
        .onChange(of: runner.sentAwaitingEmail) { _, _ in
            guard model.shouldExplainEmailLinks else { return }
            model.markEmailLinksExplained()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { explainEmail = true }       // after the green check
        }
        .sheet(isPresented: $explainEmail) { EmailCheckExplainer(openTab: nil) { explainEmail = false } }
        .confirmationDialog(Loc.t("This site did not go through"), isPresented: Binding(get: { runner.emailOffer != nil && !handoff.active && runner.phase != .noForm }, set: { _ in }), titleVisibility: .visible) {
            Button("Write the email") { if let e = runner.emailOffer { emailInstead(e) } }.accessibilityIdentifier("assisted-offer-email")
            // Already emailed them, or got it done another way: one tap says so, and the site counts as done.
            Button("Mark as done") { runner.answerEmailOffer(sent: true) }.accessibilityIdentifier("assisted-offer-mark-done")
            Button("Not now", role: .cancel) { runner.answerEmailOffer(sent: false) }
        } message: { Text("We have an email address for this site. Send your opt-out by email instead, and we mark it done. If you already did, tap Mark as done.") }
        .onAppear { handoff.markEmailed = { model.markEmailed($0) } }
        .alert("Did you send it?", isPresented: Binding(get: { handoff.confirming != nil }, set: { _ in })) {
            Button("Yes, I sent it") { handoff.answer(sent: true) }
            Button("No", role: .cancel) { handoff.answer(sent: false) }
        } message: { Text("Other mail apps do not tell us whether you sent the message. Say yes only if you did.") }
        .sheet(isPresented: Binding(get: { explainAdID != nil }, set: { if !$0 { explainAdID = nil } })) {
            if let a = explainAdID {
                AdIDExplainer(siteName: a.name, onContinue: { explainAdID = nil; Task { await model.loadAdID(for: a.batch); openEmail(a.batch) } },
                              onSkip: { explainAdID = nil; model.skipAdID(); openEmail(a.batch) })
            }
        }
        .sheet(item: $handoff.composing) { batch in
            MailComposer(to: model.recipients(for: batch).to, bcc: model.recipients(for: batch).bcc, subject: batch.subject, body: model.emailBody(for: batch)) { result in
                handoff.composeFinished(batch, sent: result == .sent)
            }
        }
        .onChange(of: runner.skippedCount) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) { showSkipped = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.easeIn(duration: 0.3)) { showSkipped = false } }
        }
        .onChange(of: runner.celebrate) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) { showSent = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.easeIn(duration: 0.3)) { showSent = false } }
        }
    }

    /// Some sites only take an opt-out by email (or the form is a dead end): the message is prepared for the person to read and send.
    private func emailInstead(_ entry: DirectoryEntry) {
        guard let batch = EmailBatch.single(entries: [entry]).first else { return }
        if model.needsAdIDExplained(for: batch) { explainAdID = (batch, entry.name); return }
        Task { await model.loadAdID(for: batch); openEmail(batch) }
    }

    private func openEmail(_ batch: EmailBatch) {
        handoff.open(batch, composesInApp: model.composesInApp, url: model.composeURL(for: batch, app: model.mailApp)) { UIApplication.shared.open($0) }
    }

    private var working: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                GuideSurface(topInset: geo.safeAreaInsets.top) {
                    // The actions come first: everything about the site as a whole in the menu, the step's own buttons beside it.
                    HStack(spacing: 10) {
                        Menu {
                            if let url = runner.page?.webView?.url ?? runner.searchPage?.webView?.url {
                                Button { UIPasteboard.general.string = url.absoluteString } label: { Label("Copy link", systemImage: "link") }
                            }
                            if let web = runner.page?.webView ?? runner.searchPage?.webView {
                                // A form that fails and asks for a refresh: reload the page, then put the details back.
                                Button {
                                    web.reload()
                                    Task { try? await Task.sleep(nanoseconds: 3_500_000_000); await runner.page?.refill() }
                                } label: { Label("Refresh the page", systemImage: "arrow.clockwise") }.accessibilityIdentifier("assisted-refresh")
                                Button { Task { await runner.page?.refill() } } label: { Label("Fill the form again", systemImage: "square.and.pencil") }.accessibilityIdentifier("assisted-fill-again")
                            }
                            if let entry = runner.current?.entry, entry.contactEmail != nil {
                                Button { emailInstead(entry) } label: { Label("Send an email instead", systemImage: "envelope") }.accessibilityIdentifier("assisted-email-instead")
                            }
                            Button {
                                if let item = runner.current { model.skipSite(item.entry.id) }
                                runner.skip()
                            } label: { Label("Skip this site", systemImage: "forward") }.accessibilityIdentifier("assisted-skip")
                            // After the first skip, the same site can be set aside for good.
                            if let item = runner.current, model.skipCount(item.entry.id) >= 1 {
                                Button(role: .destructive) {
                                    model.skipSite(item.entry.id, forever: true)
                                    runner.skip()
                                } label: { Label("Skip this site forever", systemImage: "forward.end") }.accessibilityIdentifier("assisted-skip-forever")
                            }
                            Menu {
                                ForEach(IssueKind.allCases, id: \.self) { kind in
                                    Button(kind.label) {
                                        if let item = runner.current { model.reportIssue(kind, site: item.entry.id) }
                                        runner.skip(reported: true)
                                    }
                                }
                            } label: { Label("Not working", systemImage: "exclamationmark.bubble") }
                            Button(role: .destructive) { dismiss() } label: { Label("Stop", systemImage: "xmark.circle") }
                        } label: { Image(systemName: "ellipsis.circle").font(.title2) }
                            .accessibilityLabel(Loc.t("More")).accessibilityIdentifier("assisted-more")
                        Text("Site \(runner.index + 1) of \(runner.items.count)").font(.caption.bold()).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        if case .pickingListing = runner.phase {
                            Button("Not listed") { runner.notListed() }.font(.callout).lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier("assisted-not-listed")
                            Button("This is me") { runner.confirmListing() }.buttonStyle(GuidePrimaryStyle()).accessibilityIdentifier("assisted-my-profile")
                        } else {
                            if canMarkDone || runner.emailOffer != nil { Button("Mark as done") { if runner.emailOffer != nil { runner.answerEmailOffer(sent: true) } else { Task { await runner.markDone() } } }.font(.callout.bold()).accessibilityIdentifier("assisted-mark-done") }
                            if case .needsMore = runner.phase { Button("Next site") { runner.next() }.buttonStyle(GuidePrimaryStyle()).accessibilityIdentifier("assisted-next") }
                        }
                    }
                    ProgressView(value: Double(runner.index), total: Double(max(runner.items.count, 1))).tint(Color.exnayGold)
                    Text(runner.current?.entry.domain ?? "").font(.subheadline.bold()).foregroundStyle(.white).accessibilityIdentifier("assisted-site")
                    VStack(alignment: .leading, spacing: 6) {
                        Label(instruction, systemImage: icon).font(.caption).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("assisted-instruction")
                        if let previous = runner.previousNote {
                            HStack(alignment: .top) {
                                Label(previous, systemImage: "arrow.uturn.backward.circle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("assisted-previous")
                                Spacer(minLength: 0)
                                Button { runner.previousNote = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel(Loc.t("Dismiss"))
                            }
                        }
                        if let notice = runner.notice { Label(notice, systemImage: "doc.badge.plus").font(.caption).foregroundStyle(Color.exnayGold).accessibilityIdentifier("assisted-notice") }
                        // A site that also takes opt-outs by email can be finished that way when its form is a dead end (one request per app or panel, a
                        // form that will not take taps): the same button is in the menu, but it is easy to miss there.
                        if let entry = runner.current?.entry, entry.contactEmail != nil, !runner.finished, runner.phase != .noForm, runner.phase != .loading {
                            Button { emailInstead(entry) } label: { Label("Send an email instead", systemImage: "envelope") }
                                .font(.caption.bold()).buttonStyle(.bordered).tint(Color.exnayGold).accessibilityIdentifier("assisted-email-shortcut")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GuideBoundary()
                Group {
                    if let web = runner.searchPage?.webView { WebViewHost(webView: web).id("search\(runner.index)") }
                    else if let web = runner.page?.webView { WebViewHost(webView: web).id(runner.index) }
                    else if runner.phase == .noForm, let entry = runner.current?.entry { noFormCard(entry) }
                    else { LoadingMark(title: Loc.t("Loading the form…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(maxHeight: .infinity)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    /// Whether the person can say this site is done: while it waits for them, or after a send that did not confirm.
    /// Shown instead of a page for a site with no online form.
    private func noFormCard(_ entry: DirectoryEntry) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge").font(.system(size: 44)).foregroundStyle(Color.exnayGold)
            Text("No form exists for \(entry.domain)").font(.title3.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
            Text("This site takes opt-outs by email. We write the message with the details it needs; you read it and send it.").font(.callout).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            if let mail = entry.contactEmail { Text(mail).font(.footnote.monospaced()).foregroundStyle(.white.opacity(0.6)) }
            Button { emailInstead(entry) } label: { Label("Write the email", systemImage: "envelope").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("assisted-write-email")
            HStack {
                Button("Mark as done") { runner.answerEmailOffer(sent: true) }.buttonStyle(.bordered).accessibilityIdentifier("assisted-nf-mark-done")
                Button("Skip this site") { model.skipSite(entry.id); runner.skip() }.buttonStyle(.bordered).accessibilityIdentifier("assisted-nf-skip")
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }

    private var canMarkDone: Bool {
        switch runner.phase {
        case .waitingForTerms, .waitingForCertification, .waitingForCheck, .waitingForChoice, .needsMore, .timedOut: return true
        default: return false
        }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            summaryList
            // The run is over: one clear way out, however each site ended (sent, skipped or set aside).
            Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding().accessibilityIdentifier("assisted-finish")
        }
    }

    private var summaryList: some View {
        List {
            let sent = runner.results.values.filter { if case .submitted = $0 { return true } else { return false } }.count
            Section {
                Text("Sent \(sent) of \(runner.items.count).").font(.headline).accessibilityIdentifier("assisted-summary")
                Text("Some sites email you a link to confirm. That click is yours.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Each site") {
                ForEach(runner.items) { item in
                    VStack(alignment: .leading) {
                        Text(item.entry.domain)
                        Text(runner.results[item.id]?.label ?? Loc.t("Not reached")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var instruction: String {
        if let item = runner.current, item.perRecordForm, !runner.finished {
            switch runner.phase {
            case .loading, .pacing, .sending, .sent, .noForm, .timedOut: break
            default: return Loc.t("This site has no removal form of its own: each record has one. Tap Find my record, open each record that is you, scroll to Request Removal of This Record, add your name and email, and submit it. Then tap Mark as done.")
            }
        }
        if let item = runner.current, item.blockWidget, !runner.finished {
            switch runner.phase {
            case .loading, .pacing, .sending, .sent, .noForm, .timedOut: break
            default: return Loc.t("This site hides your listing; there is no form to send. Pass the human check, search for yourself in the page, and tap Block Profile next to each result that is you. When it says blocked we move on; if it does not, tap Mark as done.")
            }
        }
        switch runner.phase {
        case .loading: return Loc.t("Loading the form and filling in your details…")
        case .pickingListing: return Loc.t("We searched this site for you. Tap your own profile in the results. If you are not in them, tap \"Not listed\". When you are on your profile, tap \"This is me\" and we do the rest.")
        case .waitingForTerms: return Loc.t("Your details are filled in. This site asks you to accept its terms: read them and accept yourself, then solve the check. We will send it after.")
        case .waitingForCertification: return Loc.t("Your details are filled in. This form asks you to tick a confirmation yourself: read it, tick it if it is true, and solve any check. We will send it after.")
        case .waitingForCheck: return Loc.t("Your details are filled in. Solve the check below and we will send it.")
        case .waitingForChoice(let what): return what.isEmpty ? Loc.t("Your details are filled in. Pick the option the form asks for below, then we will send it.") : Loc.f("Your details are filled in. Pick \"%@\" in the form below, then we will send it.", what)
        case .sending: return "Sending…"
        case .sent(let email): return email ? Loc.t("Sent. Check your email for a link to confirm.") : Loc.t("Sent.")
        case .needsMore(let why): return why == AutoOptOut.rateLimited
            ? Loc.t("The site said \"too many requests\". It limits how fast it takes them, and this company runs several of these sites. Wait a few minutes and try it again later; tap Next site to carry on.")
            : Loc.f("We pressed Send on this page but saw no confirmation (%@). If it needs one more step, do it here, then tap Next site.", why)
        case .timedOut: return Loc.t("Timed out waiting for the check.")
        case .noForm: return Loc.t("No online form exists for this site. Send an email instead: tap Write the email.")
        case .pacing(let n): return Loc.f("This company runs several of these sites and limits how fast it takes requests. Sending in %lld seconds so it is not turned away.", n)
        }
    }

    private var icon: String {
        switch runner.phase {
        case .sent: return "checkmark.circle.fill"
        case .pickingListing, .waitingForTerms, .waitingForCertification, .waitingForCheck, .waitingForChoice: return "hand.point.up.left"
        case .needsMore, .timedOut: return "exclamationmark.triangle"
        case .noForm: return "envelope"
        case .pacing: return "timer"
        default: return "hourglass"
        }
    }

    private var tint: Color {
        switch runner.phase {
        case .sent: return .green
        case .pickingListing, .waitingForTerms, .waitingForCertification, .waitingForCheck, .waitingForChoice, .needsMore, .timedOut, .noForm: return .orange
        default: return .white.opacity(0.7)
        }
    }
}


/// A big green check over the screen each time a site is sent, so a fast move to the next page is not missed.
/// What shows in place of the green check when a site is skipped (the person skipped it, or its page would not load): the site slides out and the next one comes.
struct SkippedMark: View {
    @State private var moved = false
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.orange)
                Image(systemName: "forward.fill").font(.system(size: 56, weight: .bold)).foregroundStyle(.white)
                    .offset(x: moved ? 6 : -30).opacity(moved ? 1 : 0.2)
            }
            .frame(width: 120, height: 120).scaleEffect(moved ? 1 : 0.4)
            Text("Skipped").font(.title.bold()).foregroundStyle(.orange)
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .shadow(radius: 20)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { moved = true } }
        .accessibilityElement(children: .ignore).accessibilityLabel(Loc.t("Skipped")).accessibilityIdentifier("assisted-skipped-mark")
        .allowsHitTesting(false)
    }
}

/// The waiting mark: the same round badge as the check and the skip, with a turning arrow.
struct LoadingMark: View {
    let title: String
    @State private var turning = false
    @State private var grown = false
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.exnayGold)
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 56, weight: .bold)).foregroundStyle(.white)
                    .rotationEffect(.degrees(turning ? 360 : 0))
            }
            .frame(width: 120, height: 120).scaleEffect(grown ? 1 : 0.4)
            Text(title).font(.title3.bold()).foregroundStyle(Color.exnayGold)
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .shadow(radius: 20)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { grown = true }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityIdentifier("loading-mark")
        .allowsHitTesting(false)
    }
}

struct SentCheck: View {
    @State private var grown = false
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.green)
                Image(systemName: "checkmark").font(.system(size: 64, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 120, height: 120).scaleEffect(grown ? 1 : 0.3)
            Text("Sent").font(.title.bold()).foregroundStyle(.green)
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .shadow(radius: 20)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { grown = true } }
        .accessibilityElement(children: .ignore).accessibilityLabel(Loc.t("Sent")).accessibilityIdentifier("assisted-sent-check")
        .allowsHitTesting(false)
    }
}
