#!/bin/zsh
# End-to-end check in two simulators: export from the source, import into a target that
# already holds a few identical records, export the target again and compare the two files,
# then import a second time to prove nothing is copied twice.
#   scripts/roundtrip.sh            (seeds the source first if it has no data yet)
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
source scripts/.sims
docs() { echo "$(xcrun simctl get_app_container ${(P)1} com.shimku.HealthCopy data)/Documents"; }
step() { echo "== $1"; scripts/run.sh $2 "$3" | grep -E "HC_STATUS|error:|TEST (SUCCEEDED|FAILED)" || true; cat "$(docs $2)/debug-status.txt"; echo; }

xcodebuild build-for-testing -project HealthCopy.xcodeproj -scheme HealthCopy -sdk iphonesimulator \
  -destination "id=$S" -derivedDataPath build/dd 2>&1 | grep -E "^/.*error|\*\* TEST"
swiftc -O HealthCopy/Archive/Format.swift scripts/compare/main.swift -o build/compare

# xcodebuild shuts down a simulator it had to boot, so keep both up.
xcrun simctl boot $S 2>/dev/null || true
xcrun simctl boot $T 2>/dev/null || true
if [[ "$1" != "import" ]]; then
  step "export source" S "-export"
  cp "$(docs S)/export.healthcopy" build/source.healthcopy
  ls -la build/source.healthcopy
  step "seed target with a few identical records" T "-seed partial"
fi
cp build/source.healthcopy "$(docs T)/in.healthcopy"
step "import" T "-import in.healthcopy"
cp "$(docs T)/import-result.json" build/import-1.json
step "export target" T "-export"
cp "$(docs T)/export.healthcopy" build/target.healthcopy
echo "== compare"
build/compare build/source.healthcopy build/target.healthcopy | tee build/compare.txt
step "import again" T "-import in.healthcopy -again"
cp "$(docs T)/import-result.json" build/import-2.json
