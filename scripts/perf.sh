#!/bin/zsh
# Times export and import at scale: adds ~220,000 records to the source, then copies
# everything into a freshly erased target and compares.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
source scripts/.sims
docs() { echo "$(xcrun simctl get_app_container ${(P)1} com.shimku.HealthCopy data)/Documents"; }
step() { echo "== $1"; scripts/run.sh $2 "$3" | grep -E "error:|TEST (SUCCEEDED|FAILED)" || true; cat "$(docs $2)/debug-status.txt"; echo; }
xcrun simctl boot $S 2>/dev/null || true
xcrun simctl boot $T 2>/dev/null || true
if [[ "$1" != "import" ]]; then
  [[ "$1" == "noseed" ]] || step "bulk seed" S "-seed bulk"
  step "export source" S "-export"
  cp "$(docs S)/export.healthcopy" build/source.healthcopy
  ls -la build/source.healthcopy
  xcrun simctl shutdown $T 2>/dev/null || true
  xcrun simctl erase $T
  xcrun simctl boot $T
  step "install" T "-probe"
  cp build/source.healthcopy "$(docs T)/in.healthcopy"
fi
step "import" T "-import in.healthcopy"
cp "$(docs T)/import-result.json" build/import-perf.json
step "export target" T "-export"
cp "$(docs T)/export.healthcopy" build/target.healthcopy
build/compare build/source.healthcopy build/target.healthcopy > build/compare-perf.txt
grep -E "different|missing|RESULT" build/compare-perf.txt | grep -vE " 0 missing, 0 different|, 0 missing$" || true
tail -1 build/compare-perf.txt
