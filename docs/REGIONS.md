# Which region a broker collects data about

Every site in the directory came from a US state registry, so each is tagged `US`. Other regions are added only on evidence, which is stored in the
site's `regions:` block (`list`, `evidence`, `checked`). Run `tools/tag_regions.py` (fetch, fetch-legal, ico CSV, apply); it only ever adds tags.

Signals used, in the order they were added:
1. The IAB Europe TCF Global Vendor List, matched by the vendor's privacy-policy domain (EU).
2. The site's opt-out page, privacy policy and terms of use (found by their links on the home page) naming a non-US law: GDPR, EEA, UK GDPR, PIPEDA,
   LGPD, Ley 25.326, LFPDPPP, Ley 1581, Ley 19.628, nDSG, POPIA, the NZ Privacy Act, and similar.
3. A country code in the domain.
4. The UK ICO register of data protection fee payers (published daily as a zip of about 1 million controllers, Open Government Licence): a site counts as
   present in the UK when its legal name matches a fee payer's name or trading name exactly (after dropping Inc/Ltd and similar). 71 sites matched. We use
   only the organisation name and registration number, never the contact details in that file, which can be personal data.

Counts after the 2026-10-26 pass (829 shown sites): 486 US only, 343 with at least one other region. "US only" means nothing was found, not that it was proved.

## Argentina

The AAIP (Agencia de Acceso a la Informacion Publica) keeps the Registro Nacional de Bases de Datos Personales, but publishes it only as a search by
the controller's CUIT/CUIL. We found no bulk file or dataset (searched argentina.gob.ar and datos.gob.ar), so it cannot be pulled like a US state registry.
Getting it would take a request to registrobasesdedatos@aaip.gob.ar or an access-to-information request. Until then Latin American brokers have to be
found from other sources (policies naming Ley 25.326, LGPD, LFPDPPP, Ley 1581, and regulator decisions).

## Outside the US

The app now fills forms and writes request text for the person's own country: the country field, the postal code and region, and wording that cites the
law that applies (GDPR Articles 17 and 21, UK GDPR, PIPEDA, LGPD, Ley 25.326, the Privacy Act). The person's country is set on their profile address.
Forms are filled as for US residents otherwise, so non-US automation is new and has had no real sends yet.

## Regional sites (found 2026-10-26)

`tools/regional_sites.py` looks on each broker's home page for its own sites for other countries: hreflang alternates that name a region (en-GB, fr-FR),
links to the same brand under another country domain (example.co.uk) or subdomain (uk.example.com), and region-coded paths (/en-gb/, /uk/). Language-only paths
(/fr/, /de/) are ignored because a language is not a country. Each regional site is crawled for a privacy or opt-out page and whether it has a form.

- 85 regional sites for 82 brokers were found this way; 60 have a privacy or opt-out page and 37 a form. Each one adds its region tag, with the link as evidence.
- The tool also probed the same name under the main country domains (example.fr, example.de, ...). 68 answered and link back to the broker, but a link back is
  not proof of the same company (several look like parked or unrelated domains), so they are kept as leads in the `regional_sites` list with `how: probed ...`
  and are used for neither tags nor routing.
- A person outside the US who has a strong regional site for their country is sent to it instead of the US page, and its form, when it has one, is found on
  the live page. A US resident always uses the main site.

## Languages (2026-10-26)

`tools/site_languages.py` records the languages each site is offered in (the page's `lang`, `hreflang` alternates) and the translated address of its opt-out
page, when the page lists its translations. 42 sites declare a language other than English; 25 opt-out pages list translations. A language tied to one country
(French, German, Italian, Dutch, Polish, Swedish, Japanese, Korean, ...) adds that region tag, with the evidence; English, Spanish, Portuguese, Chinese, Arabic and
Russian are recorded but add no region, since too many countries speak them. 75 tags were added this way.

When the person's app language is not English and a site lists its opt-out page in that language, the assisted flow opens that page (the tag for their own country
wins, e.g. fr-CA for Canada) and falls back to the original page if no form can be filled on it. Every page is also requested with the person's language in
`Accept-Language`, which many sites honor on their own.

Order to re-run everything: `tag_regions.py apply`, then `regional_sites.py apply`, then `site_languages.py apply` (the first rewrites the tags, the others add to them).

### Script-based language pickers

Most language menus are built by scripts, so the first pass (page tags only) found 42 sites. `tools/site_languages_browser.py` opens each home page and opt-out page in a
headless browser, looks in the rendered page for links and options named in a language's own name (Francais, Deutsch, ...) or carrying a language path or `?lang=`
parameter, and opens language menus (buttons labelled Language, globes, a current-language code) to see what is inside. It is merged into the same list (adds only).
After it ran, 78 sites are offered in a language other than English and 60 have a translated opt-out page. It found real ones: OneTrust webforms with a language
switcher, and translated privacy pages on criteo.com. Translated pages on a tracker or analytics host are dropped, and a picker with more than 15 languages adds no
region tags. A menu that opens only after a hover, or sits behind a bot check, is still missed.
