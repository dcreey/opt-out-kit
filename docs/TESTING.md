# Testing (placeholder)

Deliberately thin until the app works end to end. Layers, cheapest first:

| Layer | Where | Runs |
|---|---|---|
| Broker YAML vs `schema/broker.schema.json` | CI `registry` job | `check-jsonschema --schemafile schema/broker.schema.json brokers/*.yml` |
| Core logic (decode, queue, progress) | `Packages/OptOutKitCore/Tests` | `swift test` in that folder |
| App unit tests | `AppTests` | `xcodebuild test` (needs a simulator) |
| UI smoke test | `AppUITests` | same |

Human-only steps (CAPTCHA, phone, ID) are never automated; see docs/DESIGN.md.
TODO: mock broker site for UI flow tests, fake inbox for `wait_for_email`, live-page drift check.

Build locally: `brew install xcodegen && xcodegen generate`, then open `OptOutKit.xcodeproj`
(generated, git-ignored).
