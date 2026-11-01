#!/bin/zsh
# Archives a Release build and uploads it to App Store Connect for TestFlight.
# Needs Xcode signed in to the team's Apple ID (Xcode > Settings > Accounts) and the app
# record created in App Store Connect with bundle ID com.shimku.HealthCopy.
#   scripts/upload.sh 5      (build number; must go up with every upload)
#
# The local signing key can't be used from a non-interactive shell (codesign fails with
# errSecInternalComponent), so the archive is built unsigned, signed ad hoc with the app's
# entitlements, and Xcode's cloud signing puts the distribution signature on at export.
# Without the ad hoc step the entitlements are lost and the app can't use HealthKit, so the
# script checks a local export for them before uploading anything.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
BUILD=${1:?build number}
TEAM=29HR2P4J5B
APP=build/HealthCopy.xcarchive/Products/Applications/HealthCopy.app
rm -rf build/HealthCopy.xcarchive build/upload build/check
xcodebuild archive -project HealthCopy.xcodeproj -scheme HealthCopy -configuration Release \
  -destination generic/platform=iOS -archivePath build/HealthCopy.xcarchive \
  CURRENT_PROJECT_VERSION=$BUILD CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

# The app's entitlements plus the identifiers a signed build carries.
# PlistBuddy, not plutil: plutil reads the dots in com.apple.developer.* as nested keys.
cp HealthCopy.entitlements build/signing.entitlements
PB=/usr/libexec/PlistBuddy
$PB -c "Add :application-identifier string $TEAM.com.shimku.HealthCopy" build/signing.entitlements
$PB -c "Add :com.apple.developer.team-identifier string $TEAM" build/signing.entitlements
$PB -c "Add :get-task-allow bool false" build/signing.entitlements
codesign --force --sign - --entitlements build/signing.entitlements --timestamp=none --generate-entitlement-der "$APP"

sed 's|<string>upload</string>|<string>export</string>|' scripts/ExportOptions.plist > build/ExportCheck.plist
xcodebuild -exportArchive -archivePath build/HealthCopy.xcarchive -exportOptionsPlist build/ExportCheck.plist \
  -exportPath build/check -allowProvisioningUpdates 2>&1 | grep -E "error|EXPORT (SUCCEEDED|FAILED)"
mkdir -p build/check/ipa && unzip -q build/check/*.ipa -d build/check/ipa
if ! codesign -d --entitlements - --xml build/check/ipa/Payload/HealthCopy.app 2>/dev/null | grep -q "com.apple.developer.healthkit"; then
  echo "The signed build has no HealthKit entitlement. Not uploading."; exit 1
fi
echo "Signed build $BUILD has HealthKit. Uploading."

xcodebuild -exportArchive -archivePath build/HealthCopy.xcarchive -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath build/upload -allowProvisioningUpdates 2>&1 | grep -E "error|Upload succeeded|EXPORT (SUCCEEDED|FAILED)" | sort -u
