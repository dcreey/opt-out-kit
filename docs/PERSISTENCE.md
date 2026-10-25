# Does an opt-out last?

Brokers collect data again over time, so a removal does not always stay removed. Each directory entry has a `persistence:` block that says what the
broker's own privacy policy claims, and the app asks the person to repeat the opt-out when it is due.

## What is recorded

| `result` | Meaning | Re-up |
|---|---|---|
| `permanent` | The policy says the opt-out is kept: a suppression list, "we will not add you again", "remains opted out". | never |
| `temporary` | The policy says the data can come back, the opt-out expires, you must resubmit, or the opt-out is a browser cookie. | 6 to 12 months (the policy's own number when it gives one) |
| `unknown` | The policy does not say. Treated like `temporary`, because most brokers refill their data. | 6 months for people-search and location data, otherwise 12 |

`quote` is the sentence the verdict rests on and `source` is the policy it came from. `tools/describe_persistence.py` writes the block from the
policy text gathered by `tools/collect_about.py`. A cookie opt-out only counts as "temporary" for ad-style brokers, where the cookie is the opt-out.

## How well it works

Most policies say nothing either way, so about 90% of brokers are `unknown`. That is the honest result, not a gap to fill with guesses. A short
list of phrases decides the rest, so a policy that words it differently is missed, and a sentence can be read in the wrong context. The quote is
shown to the person so they can judge it.

## What the app does

- Each site page shows whether the opt-out lasts, the sentence behind it, when the last request was sent and when it is due again.
- A request holds until its re-up date. After that the site is back in the daily batches for its kind of broker, and the welcome-back summary says
  how many are due. Sites whose policy says the opt-out lasts never come back.
- Nothing is repeated automatically: the person does it again in their next batch.
