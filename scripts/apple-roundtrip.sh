#!/bin/zsh
# Apple's own export, end to end: the source simulator's Health app makes export.zip
# (scripts/apple-export.sh), Hëlth on the target reads and copies it, then the target is
# exported with Send and checked against what Send got from the source (the truth).
#   scripts/apple-roundtrip.sh build/apple/export.zip build/apple/truth.healthcopy
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
source scripts/.sims
ZIP=${1:A}; TRUTH=${2:A}
docs() { echo "$(xcrun simctl get_app_container ${(P)1} com.shimku.HealthCopy data)/Documents"; }
step() { echo "== $1"; scripts/run.sh $2 "$3" | grep -E "HC_STATUS|error:|TEST (SUCCEEDED|FAILED)" || true; cat "$(docs $2)/debug-status.txt"; echo; }
results() { python3 -c "
import json,sys;r=json.load(open(sys.argv[1]))['results']
t={k:sum(v.get(k,0) for v in r.values()) for k in ['copied','already','failed','skipped']}
print('   ', t); [print('    failed', k, v.get('errors')) for k,v in r.items() if v.get('failed')]" "$1"; }

xcodebuild build-for-testing -project HealthCopy.xcodeproj -scheme HealthCopy -sdk iphonesimulator \
  -destination "id=$T" -derivedDataPath build/dd 2>&1 | grep -E "^/.*error|\*\* TEST"
swiftc -O HealthCopy/Archive/Format.swift scripts/applecompare/main.swift -o build/applecompare
xcrun simctl boot $T 2>/dev/null || true

step "empty the target" T "-remove"
step "seed target with a few identical records" T "-seed partial"
step "read and copy export.zip" T "-import $ZIP"
results "$(docs T)/import-result.json"
step "export target" T "-export"
cp "$(docs T)/export.healthcopy" build/apple/target.healthcopy
echo "== compare"
build/applecompare "$TRUTH" build/apple/target.healthcopy | tee build/apple/compare.txt | grep -vE " 0 different, 0 missing, 0 extra"
step "copy the same export.zip again" T "-import $ZIP -again"
results "$(docs T)/import-result.json"
