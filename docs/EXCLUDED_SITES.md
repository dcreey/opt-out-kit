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
