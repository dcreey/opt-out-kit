# Excluded sites

Sites that were in a seed list or registry but must not be fetched, crawled, profiled or shown. The machine-readable list is
`pipeline/excluded-sites.txt`; `tools/profile_brokers.py` skips every domain in it, and removing a site's file from `directory/` keeps
every later tool (crawler, audit, description collector) away from it.

## californiaarrestrecords.org (excluded 2026-10-25)

Listed in `pipeline/census-sites.txt` as an indirect mirror of an arrest-records site. When it was reviewed:

- `https://www.californiaarrestrecords.org/` returned HTTP 200 with the page title **"VWTOTO | Discover a Modern Slot Platform with Easy
  Access and a Convenient Experience"** and an Indonesian online-gambling storefront (menu items such as "VWTOTO LOGIN", "VWTOTO DAFTAR",
  "VWTOTO LINK"). It had nothing to do with arrest records.
- `/corrections`, the path the other arrest-records sites use for removal requests, returned 404.
- The domain resolves (`149.28.49.96`), so it looks hijacked or sold on, not simply gone.
- The directory's old entry (opt-out page = the home page, signals for captcha and a listing-URL input) was a false match on that storefront.

Do not add it back, and do not submit anyone's details to it. If the real California arrest-records site returns under this name, review
it by hand and remove it from `pipeline/excluded-sites.txt` first.

<!-- excluded-table:start -->
## Business-only and non-broker sites

The app shows only opt-outs that a person can use for their own personal data. These sites are loaded by no screen and crawled by no tool. Each has an `excluded:` block in `directory/`; the list comes from `pipeline/not-personal-sites.json` (`tools/apply_exclusions.py`).

| Site | Why it is kept out | Details |
|---|---|---|
| `affinity.co` | Not a data broker | CRM software for investment firms; privacy form is for its business users |
| `americantreasurytaxsolutions.com` | Not a data broker | a tax-services firm serving individuals and businesses; it does not sell data about people |
| `bdo.com` | Not a data broker | accounting and advisory firm; its pages are for business clients, not a data broker |
| `clarivate.com` | Not a data broker | research-analytics company; its privacy form is for healthcare professionals and business users |
| `commonroom.io` | Business-only opt-out | sales-intelligence software; its only form is a demo request for business buyers |
| `communityimpact.com` | Not a data broker | a local news publisher; not a data broker |
| `deloitte.com` | Not a data broker | consulting firm; its pages are for business clients, not a data broker |
| `evs7.com` | Not a data broker | dialer software company; contact form is for business customers |
| `exa.ai` | Not a data broker | a search API for AI agents; no consumer opt-out |
| `exlservice.com` | Not a data broker | business process outsourcing company; contact form is for business inquiries |
| `hubspot.com` | Not a data broker | marketing software company; its privacy form is for its customers' contacts, not a broker |
| `informa.com` | Not a data broker | events and media group; contact route is for business |
| `klarifi.io` | Not a data broker | wastewater market data on facilities, not people |
| `modfxlabs.com` | Not a data broker | event-planning software; not a data broker |
| `narvar.com` | Not a data broker | post-purchase software for retailers; opt-out is for its business customers |
| `partech.com` | Not a data broker | restaurant software company; opt-out page is for business customers |
| `qualfon.com` | Not a data broker | call-center outsourcing company; contact form is for business inquiries |
| `similarweb.com` | Not a data broker | website-traffic analytics about sites, not people |
| `sproutsocial.com` | Not a data broker | social-media software; opt-out is for its business customers |
| `supplier.io` | Not a data broker | supplier data about companies, not people |
| `trustandwill.com` | Not a data broker | an estate-planning service; not a data broker |
| `us.com` | Not a data broker | a domain-name registry service; no personal data about people |
| `vintory.com` | Not a data broker | vacation-rental CRM software; not a data broker |
| `ziffdavis.com` | Not a data broker | a media publisher; not a data broker |
| `zoom.com` | Not a data broker | a video-meeting product site; the opt-out is a general contact route, not a broker removal |
| `zs.com` | Not a data broker | management consulting firm for businesses |
<!-- excluded-table:end -->
