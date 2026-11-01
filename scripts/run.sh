#!/bin/zsh
# Runs one debug pass of the app in a test simulator, answering Health's permission screen.
#   scripts/run.sh S "-seed full"      (S = source simulator, T = target)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
source scripts/.sims
DEV=${(P)1}
# Health's permission sheet can change under the UI test mid-lookup, which ends it early;
# the debug actions are safe to repeat, so try again (up to three times) until one finishes.
for attempt in 1 2 3; do
  rm -f "$(xcrun simctl get_app_container $DEV com.shimku.HealthCopy data 2>/dev/null)/Documents/debug-status.txt"
  TEST_RUNNER_HC_ARGS="$2" xcodebuild test-without-building -project HealthCopy.xcodeproj -scheme HealthCopy \
    -destination "id=$DEV" -derivedDataPath build/dd -only-testing:HealthCopyUITests/FlowTests/testFlow 2>&1 \
    | grep -E "HC_STATUS|\*\* TEST" | head -5
  STATUS="$(cat "$(xcrun simctl get_app_container $DEV com.shimku.HealthCopy data)/Documents/debug-status.txt" 2>/dev/null)"
  [[ "$STATUS" == debug-done* || "$STATUS" == debug-failed* ]] && break
  echo "attempt $attempt ended early ($STATUS), retrying"
done
