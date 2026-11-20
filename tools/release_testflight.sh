#!/bin/bash
# Archive, export and upload one TestFlight build.
#
#   ASC_KEY_ID=...  ASC_ISSUER_ID=...  tools/release_testflight.sh
#
# The API key file must be in ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (altool finds it there). Raise CFBundleVersion in project.yml first:
# xcodegen rewrites App/Info.plist from it, and Apple rejects a repeated build number. Raise it in the ShareExtension target too: the two must match.
set -euo pipefail
: "${ASC_KEY_ID:?set ASC_KEY_ID}"; : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
TEAM="${TEAM_ID:-C84MKW6B2K}"
OUT="$(mktemp -d)"
cd "$(dirname "$0")/.."
# The TestFlight gate: only a commit whose unit tests (CI) passed on GitHub is built and uploaded. Integration (the UI tests and the run over every
# site) is not required for TestFlight: it gates the App Store release (tools/release_gate.py without --for testflight, before submitting for review).
python3 tools/release_gate.py --for testflight
# The API key also signs in for provisioning, so a new bundle id (the share extension) gets its profile without an Xcode account.
AUTH=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
xcodegen generate
# -skipPackagePluginValidation: the core package's CatalogPlugin compiles the app's data into Catalog.sqlite during the build (a command-line build
# would otherwise stop to ask whether to trust it).
xcodebuild archive -skipPackagePluginValidation -project OptOutKit.xcodeproj -scheme OptOutKit -configuration Release -destination 'generic/platform=iOS' -archivePath "$OUT/Exnay.xcarchive" -allowProvisioningUpdates "${AUTH[@]}"
cat > "$OUT/Export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string><key>destination</key><string>export</string>
<key>teamID</key><string>$TEAM</string><key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Exnay.xcarchive" -exportOptionsPlist "$OUT/Export.plist" -exportPath "$OUT/ipa" -allowProvisioningUpdates "${AUTH[@]}"
xcrun altool --upload-app -f "$OUT/ipa/OptOutKit.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "Uploaded from $OUT"
