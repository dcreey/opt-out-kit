# Signals that you are still being tracked, and who watches the trackers

Research notes, 2026-10-21. Sourced from the pages linked below; where a search did not confirm something it is marked
**unverified**. This is input for the app's roadmap, not a claim about what the app does today.

## 1. Who tracks the trackers

| Who | What they publish | Use for this app |
|---|---|---|
| [WhoTracks.me](https://WhoTracks.Me/explorer.html) (Ghostery) | Monitors the data collectors on the top 10,000 websites; the database is reusable by other privacy tools | Ground truth for which third parties a site loads |
| [DuckDuckGo Tracker Radar](https://giga.law/daily-news/2020/3/8/duckduckgo-to-share-data-about-online-trackers-to-enhance-privacy) | Open dataset of tracker domains (5,000+ domains from 1,700+ companies at launch), with prevalence, fingerprinting and cookie behavior | Bundle a snapshot to label trackers on-device |
| [The Markup Blacklight](https://themarkup.org/blacklight/2024/03/13/blacklight-updated-with-new-tracking-info-and-caching-options) | Scanner that compares a site's network traffic with EasyPrivacy and Tracker Radar lists | Method to copy: load a page, record third-party requests, match against lists |
| [Exodus Privacy ETIP](https://f-droid.org/ca/2021/02/22/exodus-etip-canonical-database-for-tracking-trackers.html) | Canonical tracker signatures for Android apps | Android phase, and a model for app-side checks |
| [EFF Cover Your Tracks](https://coveryourtracks.eff.org/about) | Tests whether your browser blocks tracking ads and invisible trackers, and how unique your fingerprint is | A link-out: it measures the browser, not the brokers |
| [Privacy Rights Clearinghouse](https://privacyrights.org/resources-tools/reports/why-are-hundreds-data-brokers-not-registering-states) | Compared five state registries (April 2025 data): 750 unique broker groups, and many registered in one state but not another | Source for "which brokers exist" beyond our 214; flags brokers hiding from registries |
| State registries (California, Vermont, Texas, Oregon) | Legal lists of registered brokers; each state excludes different entities | Seed list for the directory; California's has 581 entries as of June 2026 (see docs/DESIGN.md) |
| [Consumer Reports](https://advocacy.consumerreports.org/press_release/consumer-reports-evaluation-of-people-search-site-removal-services-finds-that-they-are-largely-ineffective/) | Aug 2024 test of removal services: 32 volunteers, 4 months, only 117 of 332 listings (35%) removed | The independent benchmark that our verification step exists to beat |
| [CalPrivacy enforcement](https://www.gov.ca.gov/2026/08/13/icymi-california-takes-historic-action-against-data-brokers/) | Fined a broker $116,490 (Aug 2026), the first action under both the CCPA and the Delete Act | Proof the DROP rules are being enforced |

Not found in these searches (do not rely on them): a consumer-facing way to confirm a broker really deleted data after a
DROP request, and any data on re-listing rates. Search results also pointed to vendor blogs with conflicting numbers;
treat those as marketing.

## 2. Signals that you are still exposed

Ordered by how well the app can observe them without a server.

| Signal | How to observe it | Fit for Opt-Out Kit |
|---|---|---|
| **Listed on a people-search site** | Search the site for your name (docs/VERIFICATION.md) | Built for 14 sites; guided self-check for the rest |
| **Re-listed after removal** | Re-run the check on a schedule | Built (Verified / Listed again) |
| **Listed in a state registry's brokers' customers** | Not observable: registries list brokers, not their data subjects | None; use registries to find brokers |
| **Spam or calls to a unique address** | Use a different alias per broker when opting out; mail to that alias later is a resale signal. A [Krebs on Security discussion](https://krebsonsecurity.com/2022/08/the-security-pros-and-cons-of-using-email-aliases/comment-page-3) notes aliases are easy to filter out, and the [Canary Trap](https://addons.mozilla.org/de/firefox/addon/canary-trap/) extension automates per-site aliases | The app already plans alias emails for one-opt-out-per-address brokers; reading the inbox is out of scope, so the user would report hits |
| **Trackers on sites you visit** | Blacklight-style scan of a page against tracker lists | Possible later: a "scan this site" tool using a bundled Tracker Radar snapshot |
| **Browser fingerprint** | [Cover Your Tracks](https://coveryourtracks.eff.org/about) | Link-out only |
| **Global Privacy Control (GPC)** | The signal tells sites to treat you as opted out of sale and sharing; the official test page is globalprivacycontrol.org. Safari 27 support is reported by a forum thread but **unverified** | Document how to turn it on; the broker pages we read honor it in places (CourtRecords.us says it honors GPC) |
| **Data-breach exposure** | Breach-notification services such as Mozilla Monitor; its free tier does a one-time data-broker scan ([Mozilla](https://blog.mozilla.org/mozilla/introducing-mozilla-monitor-plus-a-new-tool-to-automatically-remove-your-personal-information-from-data-broker-sites/), 2024; check current terms) | Out of scope; a link-out |
| **Right-to-know request** | Ask a broker what it holds under a state privacy law and compare | Strongest proof of deletion, but slow and per broker; candidate for the guided flow's last step |

## 3. What this means for the roadmap

1. The broker check is the only signal the app can measure itself, so spend effort there, and keep it honest about
   what it cannot see (docs/VERIFICATION.md).
2. Use independent facts to frame results. Consumer Reports found 35% of listings removed after four months, so a
   "Listed again" or "still listed after 30 days" result is normal, not a failure of the user.
3. Add **alias emails** as a first-class feature: one address per broker turns later spam into evidence.
4. A **tracker scan** (Blacklight method with a bundled Tracker Radar snapshot) is the natural second product: it answers
   "who is tracking me on this site" on-device. Bigger scope; separate project.
5. Use the registries to grow the directory, and Privacy Rights Clearinghouse's finding that many brokers skip
   registries to explain why the list can never be complete.
