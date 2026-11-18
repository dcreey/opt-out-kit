# Principles

What Exnay is and will stay. These are commitments, not preferences: a change that breaks one needs this file changed first, in the open, with the reason.
Where a principle is enforced by a test or a build rule, the enforcement is named, so the rule cannot drift quietly.

## 1. Always free

- The app is free to download and free to use, all of it. No paid tier, no subscription, no "pro" broker list, no limit on sites, re-ups or languages.
- No ads, no tip jar inside the app, no affiliate links, no sponsored placement in the directory or the daily queue. Money must never decide which
  broker is ranked, shown or hidden.
- The source is open (MIT, see `LICENSE`). Anyone may fork it. The directory data (`directory/`) is part of that: it is the product, not a hook to sell.
- Nothing is monetized indirectly either: no selling or sharing of data (there is none to sell, see 2), no "partner" referrals, no paid placement for
  a paid removal service. If the app ever points at a paid service it is because the free route does not exist, and it says so.
- Costs we do carry (an Apple developer account, builds) are ours. They never become a reason to add a server, a wall or a fee.

## 2. Never tracks. No backend. Everything lives on the device

- There is no Exnay server, no account, no sign-in, no analytics, no crash reporter, no telemetry, no remote config and no push service.
  Nothing is reported anywhere, and no screen, setting or wording says or implies otherwise.
- What a person enters is stored encrypted on their phone and goes only to the broker site they are opting out of, only the fields that site needs, and only
  when the person has confirmed. It is never sent to us, to a third party, to an AI service or to a CAPTCHA-solving service.
- The only network traffic is to broker pages and email links the person opened, and (for the live form) pages the directory points at.
  No SDK that phones home goes into the build, including "privacy-friendly" ones. Adding any dependency means checking what it contacts.
- Because there is no server there is nothing to breach, subpoena or monetize. The accepted trade-off is that nothing can be recovered from us:
  lose the phone and the data goes with it (backups are the person's own).
- Progress, streaks and scores live on the device. No leaderboards, no friend lists, no sharing of results.
- Reminders are local notifications. Nothing is scheduled from a server.
- "Not working" and similar marks stay on the phone. Fixing the directory happens through public pull requests and audits we run ourselves, never through
  reports collected from users' devices.

## 3. Privacy law education

- The app teaches people that they have rights and how to use them. Opting out is the action; understanding why it works is the lasting value.
- Every request cites the law that applies to the person's place (CCPA/CPRA and the other US state laws, GDPR, UK GDPR, PIPEDA, LGPD, Ley 25.326, ...),
  and the app explains in plain language what that law gives them: to know, delete, correct and opt out, the deadlines brokers must meet, and who to
  complain to if a broker ignores a request.
- Each kind of broker has a briefing with a best-case and a worst-case example, so a person learns what the data is used for before deciding.
- Each state and country has a short, sourced summary of its law, its regulator and its broker registry (`jurisdictions/`). Where there is no law or no registry,
  the app says so instead of implying a right that does not exist. Differences between places (an opt-out that lasts, a registry, a one-stop service
  such as California's DROP) are explained, not hidden.
- Teaching is accurate and cautious: sourced, dated, and marked as education, not legal advice. When a law changes or a source is unclear, the app says that.
- A person should come away able to do this without the app: knowing what to ask for, who to ask, and what to do when they are ignored.
- The education is built in, free and on-device like everything else: no course, no sign-up, no content fetched from a server.

## 4. Built AI-first, validated by people

- The code, the directory, the tests and the docs are written and maintained by AI agents working with a human maintainer. The maintainer decides what the
  app is and what it will not do; agents do the building.
- Human users are the validators. A person testing on a real phone, with real broker pages, is the source of truth for whether something works. Agent
  output (a passing test, a rendered screenshot, a crawl result) is evidence, not proof, and is described that way.
- Real sends, real forms and real emails are what count. A flow is not called "automatic" until a reviewed real send has worked (see
  [AUTOMATION.md](AUTOMATION.md) and [TESTING.md](TESTING.md)).
- Anything an agent could get wrong must be checkable by a person: every claim in the directory carries its evidence (the quote, the URL, the date it was
  checked), so a human can verify it in a minute without trusting the agent.
- Agents work in the open: changes land as ordinary commits with tests and doc updates, and a person can read the history to see what changed and why.
- The maintainer's report of a bug on a real device outranks every automated check. Reproduce it, fix it, then add the test that would have caught it.

## 5. The person is in control

- The person does the human steps: the CAPTCHA, the confirm click, the ID or phone step. The app never solves a human check, never uses a service to do so, and
  never ticks a box that certifies something for them. In the guided and semi-automated flows on screen the person presses the page's own button. The background
  run (decided 2026-11-17: a full pass over every site that can be tried, then a repeat every 3 months and a full re-test every 6) may also fill and send a form itself; it counts a site done only when it sees the confirmation, and anything that does not go through is handed back to the person's queue.
- It never accepts terms on someone's behalf without a reviewed list, and never fills a sign-up, newsletter, demo or contact form. A test fails if one is
  set to be filled automatically.
- It asks rather than guesses. When a link could belong to several sites (shared privacy-portal providers) the app asks which site it is. When a site is
  already finished and a link arrives, it asks whether more work is needed.
- It never claims more than it did. A site is "done" when the person says so or a reviewed result shows it, not because a page loaded.
- Sites that carry a caution (a face photo, business details) show the page and put nothing of the person's in.
- It does not give legal advice. Pages change often, so the directory records when each was last checked.

## 6. Honest about what is known

- Unknown stays unknown. About 90% of brokers do not say whether an opt-out lasts, and the app says "unknown" rather than guessing.
- A site is closed or excluded only with written evidence (at least four lines, and no remaining way to opt out); a test enforces it. A site on the to-do
  list must have a working page or a mailable address, which `tools/audit_reachability.py` re-checks.
- Limits are written down: what an audit proves (a page loads, a domain accepts mail) and what it does not (that the form works, that the mailbox exists).
- Outside the US the directory is newer and has had no real sends yet, and the app and docs say so.

## 7. Protect what works

- The semi-automated "Solve and send" flow is the most trusted. Share logic and UI across flows instead of copying it, and do not break it to improve
  another flow.
- Every behavior gets a test where it can: a Mac test first (`swift test --package-path Packages/OptOutKitCore`, `Packages/AssistedRunLogic`), otherwise a
  simulator test. Each flow is listed in [TESTING.md](TESTING.md).
- The docs are part of the change. Behavior and docs are updated together and before the commit, so no doc contradicts the app.
- The directory is data, one YAML file per broker, so a contributor fixes breakage with a pull request, not a code change.

## 8. For everyone

- Translated: French, Spanish and German, built and checked with `tools/l10n.py`. Where a broker offers its page in the person's language, that page is used.
- Works for people outside the US as well as inside, with the right law cited for each place.
- Plain language over jargon. The person should never need to know what a "live form" or a "tenant address" is.
- Accessible by default: dynamic type, VoiceOver labels and no meaning carried by color alone.

## Changing this file

A principle changes only by an explicit decision from the maintainer, recorded in the commit message. Agents must not weaken one to make a task easier;
if a task seems to need it (a server, an analytics SDK, a paid feature), stop and ask.
