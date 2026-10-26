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
