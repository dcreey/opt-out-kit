import SwiftUI
import MessageUI
import WebKit
import OptOutKitCore

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
    /// Test hook: render this HTML instead of loading the site, so a test can imitate a form and a human check.
    var htmlOverride: String?
    private static var reasons: [String: String] = [:]
    func failureReason(for form: OptOutForm) -> String? { Self.reasons[form.page.absoluteString] }
    func discoveredEmail(for form: OptOutForm) -> String? { Self.foundEmails[form.page.absoluteString] }
    private static var foundEmails: [String: String] = [:]
    /// When set, the form is found on the live page and filled from these details (the stored crawl is only a hint).
    var person: Person?
    var advertisingID: String?
    /// Accepts a site's "I agree" prompt for the person when they allowed it; nil means the person always does.
    var termsPolicy: TermsPolicy?

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
        Self.reasons[form.page.absoluteString] = nil; Self.foundEmails[form.page.absoluteString] = nil
        do {
            if let htmlOverride { try await session.loadHTML(htmlOverride) } else { try await session.load(URLRequest(url: form.page), within: 15) }
        } catch { NSLog("OOK load failed %@: %@", form.page.absoluteString, "\(error)"); session.close(); return nil }
        await session.settlePage(maxWait: 10)
        _ = await session.denyCookies()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = await session.denyCookies()
        await session.hideConsentOverlays()
        return await prepareLoaded(session: session, form: form, plan: plan, listingURL: listingURL)
    }

    /// A site with no readable form, or one nothing of the person's may be put into: the page is loaded and kept open. `fillNothing` shows it as it is (no terms are accepted, nothing is
    /// clicked or filled); otherwise it is clicked through to a request form when one hides behind a button, filled as far as it can be, and held for the person to finish.
    func prepareHeld(_ form: OptOutForm, plan: FillPlan, fillNothing: Bool) async -> AssistedPage? {
        let session = WebViewSession.make()
        Self.reasons[form.page.absoluteString] = nil; Self.foundEmails[form.page.absoluteString] = nil
        do {
            if let htmlOverride { try await session.loadHTML(htmlOverride) } else { try await session.load(URLRequest(url: form.page), within: 15) }
        } catch { NSLog("OOK load failed %@: %@", form.page.absoluteString, "\(error)"); session.close(); return nil }
        await session.settlePage(maxWait: 10)
        _ = await session.denyCookies()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = await session.denyCookies()
        await session.hideConsentOverlays()
        if fillNothing { return WebAssistedPage(session: session, plan: FillPlan(values: [], verdict: .ready)) }
        return await prepareLoaded(session: session, form: form, plan: plan, holdWithoutForm: true)
    }

    /// Everything after the page has loaded: finding the opt-out form, the others beside it, filling them in. Solve and send and Email links both use this, so a
    /// kind of page one of them can handle is handled by the other. `keepOpenWithoutForm` leaves the page on screen for the person when no form is found;
    /// `advanceOnlyWithoutForm` (a page already holding its form, as an emailed link's page does) clicks through to a request form only when none is there.
    func prepareLoaded(session: WebViewSession, form: OptOutForm, plan: FillPlan, listingURL: URL? = nil, keepOpenWithoutForm: Bool = false, advanceOnlyWithoutForm: Bool = false, holdWithoutForm: Bool = false) async -> AssistedPage? {
        let page = WebAssistedPage(session: session, plan: plan)
        page.termsPolicy = termsPolicy
        if let person {
            if advanceOnlyWithoutForm {
                if LiveFormPicker.pick(await session.discoverFormsDeep(), pageContext: await session.pageContext()) == nil { _ = await session.advanceToRequestForm(loose: true) }
            } else { _ = await session.advanceToRequestForm() }
            if await session.chooseNameTab() { try? await Task.sleep(nanoseconds: 600_000_000) }
            if await session.chooseRightsPicker() { try? await Task.sleep(nanoseconds: 800_000_000) }
            var found = await session.discoverFormsDeep()
            // Only a form for a later step is showing (its email box is switched off): the page's intro button opens the real one.
            if LiveFormPicker.pick(found, pageContext: await session.pageContext()) == nil, found.contains(where: { $0.fields.contains { $0.type == "email" && $0.disabled == true } }),
               await session.pressIntroNext() { found = await session.discoverFormsDeep() }
            guard let live = LiveFormPicker.pick(found, pageContext: await session.pageContext()) else {
                Self.reasons[form.page.absoluteString] = "noform"
                // No form and (perhaps) no address on file: an address on the page itself can still be offered.
                Self.foundEmails[form.page.absoluteString] = ContactEmailPicker.best(await session.pageEmails(), pageHost: form.page.host ?? "")
                NSLog("OOK no form %@: %@", form.page.absoluteString, found.map { "[\($0.fields.filter(\.visible).map(\.label).joined(separator: ",")) | \($0.buttons.joined(separator: ","))]" }.joined(separator: " "))
                if holdWithoutForm { await session.scrollChallengeIntoView(); return page }          // the person works on the page itself; nothing is sent for them
                if !keepOpenWithoutForm { session.close() }
                return nil
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
            // The page's other opt-out forms, in page order: each is filled and sent after this one.
            let context = await session.pageContext()
            page.queueMoreForms(found.filter { $0.token != live.token && LiveFormPicker.isDedicatedOptOut($0, pageContext: context) })
        }
        await page.refill()
        if let token = page.currentFormToken { await session.scrollFormIntoView(token: token) }
        await session.scrollChallengeIntoView()
        return page
    }
}

@MainActor
final class WebAssistedPage: AssistedPage {
    /// The page's web view (the app's own tests clear a check on it the way a person would).
    let session: WebViewSession
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
    var termsPolicy: TermsPolicy?
    private var termsTriedFor: URL?
    /// How long to wait for the page to settle after pressing send. Solve and send waits long; the monthly run uses the time it was given.
    var maxWait: TimeInterval = 20
    /// What the last fill did, so a run that cannot ask the person (the monthly one) can say why it could not go on.
    private(set) var lastFill: (filled: Int, unmatchedRequired: [String]) = (0, [])
    private var unresolvedChoices: [String] = []
    private var textBeforeChoices = ""
    private var planVerdict: FillPlan.Verdict = .ready
    var currentFormToken: String? { liveForm }
    /// The text that appeared on the page after the last press of send (empty when nothing changed; nil until send was pressed), kept with the run's result
    /// (`OptOutAttempt.pageSaid`) only for a form that was sent.
    private(set) var lastSaid: String?
    private var moreLiveForms: [LiveForm] = []
    var formsRemaining: Int { moreLiveForms.count }
    func queueMoreForms(_ forms: [LiveForm]) { moreLiveForms = forms; for f in forms { knownSignatures.insert(WebAssistedDriver.signature(f)) } }

    /// The next opt-out form on the page, filled in. A form that cannot be filled (a device ID the person did not allow us to read) is left for them.
    func moreForms() async -> Bool {
        guard let person, let pageURL else { return false }
        while !moreLiveForms.isEmpty {
            let next = moreLiveForms.removeFirst()
            let form = next.asOptOutForm(page: pageURL)
            var adID = advertisingID
            if adID == nil, AdvertisingID.isAsked(by: form.fields) { adID = await AdvertisingID.current() }
            let nextPlan = FormFiller.plan(for: form, signals: nil, person: person, listingURL: listingURL, advertisingID: adID)
            guard case .ready = nextPlan.verdict, !nextPlan.values.isEmpty else { continue }
            liveForm = next.token; session.chosenForm = next.token; plan = nextPlan; planVerdict = nextPlan.verdict; advertisingID = adID
            await session.scrollFormIntoView(token: next.token)
            _ = await session.fillLive(plan.values)
            _ = await session.chooseRequestOptions(form: next.token, ownerMayConfirm: ownerMayConfirm)
            _ = await session.chooseCustomMenus(state: stateName)
            return true
        }
        return false
    }

    init(session: WebViewSession, plan: FillPlan) { self.session = session; self.plan = plan }

    func useLive(form token: String, plan: FillPlan, ownerMayConfirm: Bool, stateName: String? = nil) { liveForm = token; session.chosenForm = token; planVerdict = plan.verdict; self.plan = plan; self.ownerMayConfirm = ownerMayConfirm; self.stateName = stateName }

    func remember(person: Person, advertisingID: String?, listingURL: URL? = nil, page: URL, signature: String) { self.listingURL = listingURL; self.person = person; self.advertisingID = advertisingID; pageURL = page; knownSignatures = [signature] }

    func adoptNewForm() async -> Bool { await adoptNewForm(force: false) }

    /// `force`: the fill itself asked for the rescan (Fill again, the first fill, each send), so being in a box does not stop it. What the person typed is kept either way:
    /// a box they typed in carries their mark and is never overwritten.
    func adoptNewForm(force: Bool) async -> Bool {
        if !force, await session.userIsTyping() { return false }          // never fill or click on its own while the person is typing in a box
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
        liveForm = new.token; session.chosenForm = new.token; plan = livePlan; planVerdict = livePlan.verdict; knownSignatures.insert(sig)
        // What the person already typed is kept; only empty boxes of the new form are filled.
        _ = await session.fillLive(plan.values, keepExisting: true)
        _ = await session.chooseRequestOptions(form: new.token, ownerMayConfirm: ownerMayConfirm)
        _ = await session.chooseCustomMenus(state: stateName)
        _ = await session.chooseAutocomplete(state: stateName)
        _ = await session.chooseTileButtons()
        // More emails or phones than boxes: press the page's "Add another" button; the form then reads as a new one and its new boxes are filled.
        if await session.addAnotherBoxes(form: new.token, emails: person.emails.count, phones: person.phones.count) > 0 { _ = await adoptNewForm(force: force) }
        return true
    }

    var webView: WKWebView? { shown }
    func present() { if shown == nil { shown = session.presentable() } }

    func blockers() async -> [AssistedBlocker] {
        var out: [AssistedBlocker] = []
        if await session.hasTermsPrompt() {
            // Tried once per page: the person's approved list decides, and everything else is left for them.
            let url = session.webView.url
            if termsTriedFor != url, !(await session.userIsTyping()) { termsTriedFor = url; _ = await session.acceptTermsIfAllowed(policy: termsPolicy, domain: url?.host ?? pageURL?.host ?? ""); await refill() }
            if await session.hasTermsPrompt() { out.append(.terms) }
        }
        if let text = await session.pendingCertification() { out.append(.certify(text)) }
        if let why = await session.visibleChallenge() { out.append(.check(why)) }
        if await session.emptyCodeField() { out.append(.check("a code to type")) }
        if await session.codeBoxInUse() { out.append(.check("a code you are typing")) }      // never send on the first letter of a check the person is still typing
        // A required menu or box the app had no value for (a state list that does not offer the person's state, a request type): the person picks.
        if let liveForm, let what = await session.emptyRequiredChoice(form: liveForm) { out.append(.choose(what)) }
        return out
    }

    /// Why this page cannot be sent without the person, in words: for a run that has nobody to ask (the monthly one). Nil when the form is filled and nothing is missing.
    var problem: String? {
        switch planVerdict {
        case .ready: break
        case .needsData(let what): return "the form asks for \(what.joined(separator: ", ")), which we do not hold"
        case .needsYou(let why): return why
        }
        if lastFill.filled == 0 { return "the form's fields could not be filled in" }
        if let miss = lastFill.unmatchedRequired.first { return "the form's menu does not offer \(miss.isEmpty ? "your details" : miss), so this form does not apply to you" }
        if let missing = unresolvedChoices.first { return "the form needs a choice we cannot make for you (\(missing))" }
        return nil
    }

    /// Some forms send themselves the moment a choice is made. When the page, since the last fill, shows a confirmation, that is the result.
    func earlyConfirmation() async -> SubmitOutcome? {
        let now = await session.visibleText()
        guard now != textBeforeChoices, case .submitted(let email) = FormRun.classifyConfirmed(FormRun.newText(before: textBeforeChoices, after: now)) else { return nil }
        return .submitted(awaitingEmail: email)
    }

    func refill() async {
        defer { Task { await notePresses() } }
        if liveForm != nil {
            // Every fill reads the page again first: boxes and forms that appeared after the first look (a script-built form, a step opened by a click) are found and filled too.
            _ = await adoptNewForm(force: true)
        }
        if let liveForm {
            textBeforeChoices = await session.visibleText()
            lastFill = await session.fillLive(plan.values)
            let options = await session.chooseRequestOptions(form: liveForm, ownerMayConfirm: ownerMayConfirm)
            unresolvedChoices = options.unresolved
            _ = await session.chooseCustomMenus(state: stateName)
            let typedAhead = await session.chooseAutocomplete(state: stateName)          // a "State of Residence" that only counts a picked option
            _ = await session.chooseTileButtons()
            // Choosing "remove my information" (or a state) can reveal more boxes (name, birth year): read the form again and fill those too.
            if options.chosen > 0 || typedAhead > 0 { _ = await adoptNewForm(force: true) }
        } else { _ = await session.fillFields(plan.values) }
    }

    func send() async -> SubmitOutcome {
        #if DEBUG
        // Simulator work: `-assisted-no-send` watches a real page without ever pressing its submit button.
        if ProcessInfo.processInfo.arguments.contains("-assisted-no-send") { return .filledNotSubmitted }
        #endif
        if let early = await earlyConfirmation() { return early }
        let before = await session.visibleText()
        let stepBefore = await formSignature()
        var stateBefore: (visible: Bool, url: String)?
        if let liveForm { stateBefore = await session.formState(liveForm) }
        let pressed: Bool
        if let liveForm { pressed = await session.pressLiveSubmit(form: liveForm) } else { pressed = await session.pressSubmit(for: plan.values) }
        guard pressed else { return .failed("no submit button found") }
        // In a background run the waits end in time to read the page and take its picture (`SiteRun.deadline`); elsewhere they are as before.
        await session.settlePage(maxWait: SiteRun.wait(upTo: maxWait))
        if await session.pressConfirmStep() { await session.settlePage(maxWait: SiteRun.wait(upTo: maxWait)) }
        let after = await session.visibleText()
        lastSaid = FormRun.newText(before: before, after: after)          // what appeared after sending: the confirmation, the error
        if let why = await session.visibleChallenge() { return .challenged(why) }
        let outcome = WebFormSubmitter.classifyAfterSending(before: before, after: after)
        // A multi-step form (Next, then Submit): the same form is still there with other boxes. That is its next step, not a result; the run fills it and presses again.
        if case .submitted = outcome { return outcome }
        // No confirmation wording, but the form is gone or the page moved on, and nothing on the page says it went wrong: the site took it.
        if case .failed = outcome, let liveForm, let was = stateBefore {
            let now = await session.formState(liveForm)
            let errorSeen = FormRun.classify(FormRun.newText(before: before, after: after)) != .failed("no success message was shown")
            if (!now.visible || (!now.url.isEmpty && now.url != was.url)), !errorSeen { return .submitted(awaitingEmail: false) }
        }
        if let stepBefore, let stepNow = await formSignature(), stepNow != stepBefore, !stepNow.isEmpty { return .challenged(PageFlow.nextStepMarker) }
        return outcome
    }

    /// What the form on screen asks for, to tell one step of it from the next.
    private func formSignature() async -> String? {
        guard let liveForm else { return nil }
        let forms = await session.discoverForms(waitForFrames: false)
        return forms.first { $0.token == liveForm }.map { WebAssistedDriver.signature($0) }
    }

    func pageText() async -> String { await session.viewportText() }
    func changed() async -> Bool { await session.pageChanged() }
    func awaitingCode() async -> Bool { await session.emptyVerificationCodeBox() }
    func scrollToOptOut() async -> Bool { if await session.userIsTyping() { return false }; return await session.scrollToOptOutControl() }
    func userIsTyping() async -> Bool { await session.userIsTyping() }
    private var pressBase: Int?
    /// Called after each fill: presses from here on are the person's, so a confirmation with none of them since was not caused by them.
    func notePresses() async { pressBase = await session.userPresses() }
    func pressesSinceFill() async -> Int? {
        guard let base = pressBase, let now = await session.userPresses() else { return nil }
        return max(0, now - base)
    }

    func close() { session.close() }
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
    @AppStorage("guide.collapsed") private var guideCollapsed = false
    @State private var showSkipped = false
    @StateObject private var handoff: EmailHandoff
    @StateObject private var browserHandoff = BrowserHandoff()
    private var livePage: WebAssistedPage? { runner.page as? WebAssistedPage }
    private var liveSearch: WebSearchPage? { runner.searchPage as? WebSearchPage }
    /// The web view of whichever page is on screen (the scripted pages UI tests use have one too).
    private var pageWebView: WKWebView? {
        if let live = livePage { return live.webView }
        #if DEBUG
        if let fake = runner.page as? FakeAssistedPage { return fake.webView }
        #endif
        return nil
    }
    private var searchWebView: WKWebView? {
        if let live = liveSearch { return live.webView }
        #if DEBUG
        if let fake = runner.searchPage as? FakeSearchPage { return fake.webView }
        #endif
        return nil
    }
    init(runner: AssistedRunner) { _runner = StateObject(wrappedValue: runner); _handoff = StateObject(wrappedValue: EmailHandoff(runner: runner)) }
    @State private var explainAdID: (batch: EmailBatch, name: String)?
    @State private var explainEmail = false
    @State private var intro = false

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
        .sentQuestionAlert(runner.sentQuestion)
        #if DEBUG
        // Simulator work and its UI test: `-show-sent-question` puts the "Was this sent?" question on screen as soon as the screen opens.
        .task { if ProcessInfo.processInfo.arguments.contains("-show-sent-question") { try? await Task.sleep(nanoseconds: 3_000_000_000); _ = await runner.sentQuestion.ask(awaitingEmail: false) } }
        #endif
        .finishQuestionAlert(runner.finishQuestion)
        .task {
            intro = !model.guidedIntroSeen
            while intro { try? await Task.sleep(nanoseconds: 200_000_000) }        // nothing is filled or sent while the walkthrough is open
            await runner.run()
        }
        .guidedIntro($intro) { model.markGuidedIntroSeen(); intro = false }
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
        .onAppear { handoff.markEmailed = { model.markEmailed($0) }; runner.autoSubmit = { model.autoSubmit }; runner.asksAboutFollowUp = true }
        .browserHandoffAlert(browserHandoff) {
            if runner.emailOffer != nil { runner.answerEmailOffer(sent: true) } else { Task { await runner.markDone() } }
        }
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
                GuideSurface(topInset: geo.safeAreaInsets.top, collapsed: $guideCollapsed) {
                    // The actions come first: everything about the site as a whole in the menu, the step's own buttons beside it.
                    HStack(spacing: 10) {
                        Menu {
                            PageMenu.items(web: pageWebView ?? searchWebView, idPrefix: "assisted", details: model.pageDetails, browser: browserHandoff, anotherEmailStep: { runner.flagEmailStep(); if let item = runner.current { model.addFollowUpStep(item.entry.id) } }) { await runner.page?.refill() }
                            if let entry = runner.current?.entry, entry.contactEmail != nil {
                                Button { emailInstead(entry) } label: { Label("Send an email instead", systemImage: "envelope") }.accessibilityIdentifier("assisted-email-instead")
                            }
                            if runner.canGoBack {
                                Button { runner.back() } label: { Label("Previous site", systemImage: "backward") }.accessibilityIdentifier("assisted-back")
                            }
                            Button {
                                // A site visited again keeps its result: moving on from it is not skipping it.
                                if let item = runner.current, !runner.revisiting { model.skipSite(item.entry.id) }
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
                        GuideCollapseButton(collapsed: $guideCollapsed)
                        if guideCollapsed {
                            // Rolled up: the site's name is in the top bar, with its place in the list, and nothing else of the guide shows.
                            Text(runner.current?.entry.domain ?? "").font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).layoutPriority(-1).accessibilityIdentifier("assisted-site")
                            Text("\(runner.index + 1)/\(runner.items.count)").font(.caption.bold()).foregroundStyle(.white.opacity(0.6)).fixedSize()
                        } else {
                            Text("Site \(runner.index + 1) of \(runner.items.count)").font(.caption.bold()).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        if case .pickingListing = runner.phase {
                            Button("Not listed") { runner.notListed() }.font(.callout).lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier("assisted-not-listed")
                            Button("This is me") { runner.confirmListing() }.buttonStyle(GuidePrimaryStyle()).accessibilityIdentifier("assisted-my-profile")
                        } else {
                            // Rolled up, the "Send an email instead" shortcut is an envelope here, only for a site that has an address to write to.
                            if guideCollapsed, let entry = runner.current?.entry, entry.contactEmail != nil, !runner.finished, runner.phase != .noForm, runner.phase != .loading {
                                Button { emailInstead(entry) } label: { Image(systemName: "envelope") }
                                    .buttonStyle(GuideSecondaryStyle())
                                    .accessibilityLabel(Loc.t("Send an email instead")).accessibilityIdentifier("assisted-email-icon")
                            }
                            if canMarkDone || runner.emailOffer != nil { Button("Mark as done") { if runner.emailOffer != nil { runner.answerEmailOffer(sent: true) } else { Task { await runner.markDone() } } }.buttonStyle(GuideSecondaryStyle()).accessibilityIdentifier("assisted-mark-done") }
                            if runner.awaitingNext || runner.phase == .reviewing || runner.phase == .manualSend || { if case .needsMore = runner.phase { return true } else { return false } }() { Button("Next site") { runner.next() }.buttonStyle(GuidePrimaryStyle()).accessibilityIdentifier("assisted-next") }
                        }
                    }
                    if !guideCollapsed { ProgressView(value: Double(runner.index), total: Double(max(runner.items.count, 1))).tint(Color.exnayGold) }
                    if !guideCollapsed { Text(runner.current?.entry.domain ?? "").font(.subheadline.bold()).foregroundStyle(.white).accessibilityIdentifier("assisted-site") }
                    if !guideCollapsed { VStack(alignment: .leading, spacing: 6) {
                        Label(instruction, systemImage: icon).font(.caption).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("assisted-instruction")
                        if !guideCollapsed {
                        if let previous = runner.previousNote {
                            HStack(alignment: .top) {
                                Label(previous, systemImage: "arrow.uturn.backward.circle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("assisted-previous")
                                Spacer(minLength: 0)
                                Button { runner.previousNote = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel(Loc.t("Dismiss"))
                            }
                        }
                        if runner.pageForms.total > 1 {
                            Label(Loc.f("This page has %lld opt-out forms. We send each one: form %lld of %lld.", runner.pageForms.total, runner.pageForms.current, runner.pageForms.total), systemImage: "square.stack.3d.up")
                                .font(.caption).foregroundStyle(Color.exnayGold).accessibilityIdentifier("assisted-page-forms")
                        }
                        if let notice = runner.notice { Label(notice, systemImage: "doc.badge.plus").font(.caption).foregroundStyle(Color.exnayGold).accessibilityIdentifier("assisted-notice") }
                        // A site that also takes opt-outs by email can be finished that way when its form is a dead end (one request per app or panel, a
                        // form that will not take taps): the same button is in the menu, but it is easy to miss there.
                        HStack(spacing: 12) {
                            if let entry = runner.current?.entry, entry.contactEmail != nil, !runner.finished, runner.phase != .noForm, runner.phase != .loading {
                                Button { emailInstead(entry) } label: { Label("Send an email instead", systemImage: "envelope") }
                                    .buttonStyle(GuidePillStyle(filled: false)).accessibilityIdentifier("assisted-email-shortcut")
                            }
                            AutoSubmitToggle()
                        }
                        .padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GuideBoundary()
                Group {
                    if runner.goingBack { LoadingMark(title: Loc.t("Loading the form…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let web = searchWebView { WebViewHost(webView: web).id("search\(runner.index)") }
                    else if let web = pageWebView { WebViewHost(webView: web).id(runner.index) }
                    else if runner.phase == .noForm, let entry = runner.noFormEntry { noFormCard(entry) }
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
            if runner.emailFoundOnPage { Text("We found this address on the site's own page. Check it before you send.").font(.caption).foregroundStyle(Color.exnayGold).multilineTextAlignment(.center).accessibilityIdentifier("assisted-email-found") }
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
        case .waitingForTerms, .waitingForCertification, .waitingForCheck, .waitingForChoice, .needsMore, .timedOut, .reviewing, .manualSend: return true
        case .sent: return runner.awaitingNext
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
        case .waitingForCheck: return model.autoSubmit ? Loc.t("Your details are filled in. Solve the check below and we will send it.")
                                                        : Loc.t("Your details are filled in. Solve the check below, then press the page's own button yourself.")
        case .waitingForChoice(let what): return what.isEmpty ? Loc.t("Your details are filled in. Pick the option the form asks for below, then we will send it.") : Loc.f("Your details are filled in. Pick \"%@\" in the form below, then we will send it.", what)
        case .sending: return "Sending…"
        case .sent(let email): return email ? Loc.t("Sent. Check your email for a link to confirm.") : Loc.t("Sent.")
        case .needsMore(let why): return why == AutoOptOut.rateLimited
            ? Loc.t("The site said \"too many requests\". It limits how fast it takes them, and this company runs several of these sites. Wait a few minutes and try it again later; tap Next site to carry on.")
            : Loc.f("We pressed Send on this page but saw no confirmation (%@). If it needs one more step, do it here, then tap Next site.", why)
        case .timedOut: return Loc.t("Timed out waiting for the check.")
        case .manualSend: return Loc.t("Your details are filled in. Check them, solve any check, then press the page's own button yourself. We will notice the confirmation, or tap Mark as done.")
        case .reviewing: return Loc.t("You are back on this site. Look at it or do something else here, like another form. It keeps its result unless you finish it now. Tap Next site when you are done.")
        case .noForm: return Loc.t("No online form exists for this site. Send an email instead: tap Write the email.")
        case .pacing(let n): return Loc.f("This company runs several of these sites and limits how fast it takes requests. Sending in %lld seconds so it is not turned away.", n)
        }
    }

    private var icon: String {
        switch runner.phase {
        case .sent: return "checkmark.circle.fill"
        case .pickingListing, .waitingForTerms, .waitingForCertification, .waitingForCheck, .waitingForChoice: return "hand.point.up.left"
        case .needsMore, .timedOut: return "exclamationmark.triangle"
        case .reviewing: return "arrow.uturn.backward.circle"
        case .manualSend: return "hand.point.up.left"
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
    /// When given, a Cancel button appears once the wait is long enough for the person to want out of it.
    var cancel: (() -> Void)? = nil
    @State private var turning = false
    @State private var tooLong = false
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
            if let cancel, tooLong {
                Button("Cancel", role: .cancel, action: cancel).buttonStyle(.bordered).padding(.top, 4).accessibilityIdentifier("loading-cancel")
            }
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .shadow(radius: 20)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { grown = true }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turning = true }
        }
        .task { try? await Task.sleep(nanoseconds: 6_000_000_000); withAnimation { tooLong = true } }
        .accessibilityElement(children: cancel == nil ? .ignore : .contain).accessibilityLabel(title).accessibilityIdentifier("loading-mark")
        .allowsHitTesting(cancel != nil)
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
