#!/bin/zsh
# Remove on the target, then import a hand-made file with the cases the simulator can't make.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
source scripts/.sims
docs() { echo "$(xcrun simctl get_app_container ${(P)1} com.shimku.HealthCopy data)/Documents"; }
xcrun simctl boot $T 2>/dev/null || true
swiftc HealthCopy/Archive/Format.swift scripts/synthetic/main.swift -o build/synthetic && build/synthetic build/synthetic.healthcopy
[[ "$1" == "noremove" ]] || { echo "== remove"; scripts/run.sh T "-remove"; echo "removed $(cat "$(docs T)/removed.txt")"; }
echo "== import edge cases"; scripts/run.sh T "-import $PWD/build/synthetic.healthcopy"
python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
for k,v in sorted(d['results'].items()): print(' ', k.replace('HKQuantityTypeIdentifier','Q:').replace('HKCategoryTypeIdentifier','C:'), {x:v[x] for x in v if v[x]})" "$(docs T)/import-result.json"
echo "== export target"; scripts/run.sh T "-export"; cp "$(docs T)/export.healthcopy" build/target-edge.healthcopy
