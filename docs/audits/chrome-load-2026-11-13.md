# Chrome load check, 2026-11-13

Every site with a request form on file (408) was opened in real Chrome (`tools/chrome_load_check/run.py`, phone-sized window, no personal data) and read with the app's own picking rules (`h.js` is built from `LiveFormPicker.swift`). The run takes the app's pre-steps (cookie refusal, "Start / Opt out" buttons, the request-type menu outside forms, an intro Next) and **types nothing and presses no submit button**. Raw rows: `chrome-load-2026-11-13.jsonl`. Limits: frames are not read here (the app reads them), so portal pages that sit in a frame show as "no form" below; headless Chrome is refused by some bot checks that a person's phone passes.

| Result | Sites |
|---|---|
| A form was picked | 325 |
| No form picked | 76 |
| Blocked by a bot check | 3 |
| Page gone (404) | 2 |
| Page gone (410) | 1 |
| Timed out | 1 |

## Pages gone or unreachable (fix the directory)

- `firstorion.com`: https://privacy.firstorion.com/opt-out/step-one (404)
- `getrev.ai`: https://getrev.ai/privacy-request (404)
- `usatrace.com`: https://www.usatrace.com/your-privacy/ (410)
- `redidata.com`: https://www.redidata.com/opt-out-form/ (timeout)

## Blocked by a bot check in headless Chrome

- `allantgroup.com`: https://allantgroup.com/privacy-policy
- `hireez.com`: https://app.hireez.com/ownyourdata
- `visitiq.io`: https://visitiq.io/opt-out/

## Picked, but worth a look (one box only, or no data box)

- `adagio.io`: Country:select* | Generate Request Email Template
- `agile-ed.com`: If you prefer to submi:text | Submit
- `alphonso.tv`: Enter Your Email:text | Submit/Cancel
- `atmospherik.ai`: Email (optional, to ap:email | Submit universal opt-out
- `checkpeople.com`: Email:email* | Continue
- `clearview.ai`: Select a File:file*(DIS) | Submit
- `cybba.com`: Email:email* | Submit
- `farmers.com`: Captcha:text | Submit
- `fullcontact.com`: United States:text | Continue
- `growbots.com`: Please type your Email:text* | Learn more/Submit/Clear form
- `information.com`: Email:email* | Continue
- `inmar.com`: Enter your email addre:text | Opt-out Email Address
- `nexxen.com`: Tell us your country o:select | Submit
- `nextroll.com`: Type your email:text | 
- `penlink.com`: Enable Do Not Sell or :checkbox[=on] | 
- `stirista.com`: E-mail:email | Submit
- `truepeoplesearch.com`: Please choose from the:select | 

## No form picked

- `01advertising.com` (scriptable): 01Advertising - 🚀 Elevate Your Advertising ™
- `360mediadirect.com` (guided): Privacy Center
- `affordablebackgroundchecks.com` (unknown) CAPTCHA: Contact Us | Affordable Background Checks
- `aidentified.com` (guided) CAPTCHA: Delete My Data
- `allwebleads.com` (guided) CAPTCHA: Unsubscribe | AWL
- `alescodata.com` (guided): Privacy Center - Alesco Data
- `altairdata.com` (unknown): Consumer Info and Opt Out - Jira Service Managemen
- `americantreasurytaxsolutions.com` (guided) INTRO-BTN: Home | American Treasury Tax Solutions Inc
- `awl.com` (guided) CAPTCHA: Unsubscribe | AWL
- `babelstreet.com` (unknown): Privacy Web Form
- `bbdirect.com` (guided) CAPTCHA: CPPA Compliance | BB Direct
- `beeswax.com` (unknown) CAPTCHA: Beeswax: RTB Bidder-as-a-Service
- `blackbaud.com` (guided): Privacy Web Form
- `buildertrend.com` (blocked): Opt Out of the Disclosure of Your Personal Informa
- `cinqdi.com` (guided): Privacy Center
- `clientcommand.com` (guided) CAPTCHA: Privacy Web Form
- `cognism.com` (unknown): Privacy Center
- `communityimpact.com` (unknown): FM 685 median removal to bring overnight lane clos
- `contactout.com` (guided) CAPTCHA: ContactOut - Find Anyone's Email & Phone
- `coxautoinc.com` (scriptable) CAPTCHA: Privacy Web Form
- `datatowin.com` (guided): Privacy Requests
- `deeprootanalytics.com` (needs_browser): Deep Root Privacy Requests
- `demandbase.com` (guided) CAPTCHA: Privacy Portal
- `digitalmediasolutions.com` (guided): Privacy Policy
- `draup.com` (scriptable): DNS Request Access: Understand Your Rights Today
- `firmable.com` (scriptable) INTRO-BTN: Profile removal request - Firmable Australia
- `forddirect.com` (guided) CAPTCHA: Privacy Web Form
- `giantpartners.com` (needs_browser) CAPTCHA: Do Not Sell My Info - All Other States - America's
- `greatlakeslists.com` (needs_browser) CAPTCHA: Great Lakes List Management
- `groundtruth.com` (guided): U.S. States Privacy Rights - GroundTruth
- `growthcode.io` (guided) CAPTCHA: Do Not Sell or Share My Personal Information — Gro
- `inboundinsight.com` (guided): Privacy Policy | Inbound Insight
- `juicebox.ai` (unknown) INTRO-BTN: Juicebox Demo Request (w Routing) LIVE March 2026 
- `kidslivesafe.com` (guided): Waiting Room powered by Cloudflare
- `koddi.com` (unknown): Privacy center - Koddi | Ad Technology for Driving
- `klarifi.io` (scriptable): Privacy center - Klarifi
- `komodohealth.com` (unknown): Privacy Web Form
- `leadfeeder.com` (guided) CAPTCHA: Leadfeeder - PrivacyCockpit
- `lightboxre.com` (unknown): Data Access Request
- `lightcast.io` (unknown): Privacy Request
- `liveintent.com` (guided): Privacy Console | LiveIntent
- `loopme.com` (unknown): Opt Out
- `mediawallah.com` (scriptable): Do Not Sell | MediaWallah
- `meettie.com` (guided) INTRO-BTN: Tie | The AI Shopper Intelligence Platform
- `monocl.com` (needs_browser) INTRO-BTN: Sign in to Monocl (ExpertInsight)
- `open-public-records.com` (unknown): Remove a Record - Open Public Records
- `onaudience.com` (guided) CAPTCHA: Opt-out - OnAudience
- `optable.co` (guided): The Agentic Advertising Platform | Optable
- `outwardmedia.com` (scriptable): Privacy Policy | Outward Media Inc
- `paramountdirectmarketing.com` (needs_browser): Paramount Direct Marketing
- `plungedigital.com` (unknown): Data Access Request
- `porchgroupmedia.com` (scriptable): Register Optout
- `postpilot.com` (unknown): PostPilot Opt-Out of Mailings Form
- `privco.com` (guided): Do Not Sell or Share My Personal Information | Pri
- `realintent.co` (needs_browser): Do Not Sell Information
- `redmob.io` (scriptable): Redmob — In-app ad monetization
- `rrd.com` (unknown): Opinion Centers America - Unsubscribe| RRD
- `salutarydata.com` (blocked) CAPTCHA: Privacy Opt-Out and Disclosure Form - Salutary Dat
- `salesintel.io` (guided) INTRO-BTN: Book a SalesIntel Demo | See Our B2B Data Platform
- `seamless.ai` (guided): Privacy Request Center | DataGrail
- `searchquarry.com` (guided): Your Privacy Choices - SearchQuarry.com
- `semantiqhealth.com` (guided): SemantIQ - Contact Us
- `socialgist.ai` (guided): Privacy Policy | Socialgist
- `skydeo.com` (guided): Login | Skydeo
- `sproutsocial.com` (needs_browser) INTRO-BTN: Do Not Sell or Share My Personal Information | Spr
- `staterecords.org` (unknown): Do Not Sell / Share My Personal Information | Stat
- `telesign.com` (guided): Data Access Request
- `trustandwill.com` (scriptable) INTRO-BTN: Privacy Policy | Trust & Will
- `tunnldata.com` (needs_browser): Tunnl Privacy Requests
- `vendelux.com` (guided) INTRO-BTN: Privacy Policy | Vendelux
- `venntel.com` (guided) CAPTCHA: Opt Out & Delete Request
- `videoamp.com` (guided) CAPTCHA: VideoAmp Offerings Privacy Policy - VideoAmp
- `windfall.com` (unknown): Data Access Request
- `xcelerated.com` (guided) CAPTCHA: Unsubscribe | Xcelerated Data
- `you.com` (unknown): Data Access Request
- `zeil.com` (unknown): Data Subject Access Request Form | ZEIL

## After the picker was tightened (same day)

Looking at the picked forms (screenshots, 40 of them by eye) found 15 that were not request forms: contact, report, quote, consultation, newsletter and sales forms (`arizonaarrests.org`, `indianaarrests.org`, `maarrests.org`, `ohioarrests.org`, `oklahomaarrests.org`, `commercesignals.com`, `datamasters.org`, `decide.co`, `exactcustomer.com`, `exlservice.com`, `newmexicodatainsights.com`, `onspotdata.com`), a page's navigation (`stackadapt.com`), a robot check (`visitiq.io`) and an account sign-in (`l2-data.com`). `LiveFormPicker` now refuses them (see `docs/FORM-FILLING.md`); a second run of the check picked **312** forms, none of the 311 good ones was lost, and the spot-checked pages showed the right form, laid out readably.
