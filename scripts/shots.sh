#!/bin/zsh
# Clean screenshots of every step, from the test simulators (which already have Health access).
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
source scripts/.sims
APP=build/dd/Build/Products/Debug-iphonesimulator/HealthCopy.app
OUT=screenshots; mkdir -p $OUT
for d in $S $T; do
  xcrun simctl boot $d 2>/dev/null
  xcrun simctl status_bar $d override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 --operatorName ""
  xcrun simctl install $d $APP
done
docs() { echo "$(xcrun simctl get_app_container $1 com.shimku.HealthCopy data)/Documents"; }
# run DEVICE NAME WAIT ARGS...: launch, wait for the debug action (or WAIT seconds), screenshot
run() {
  local dev=$1 name=$2 wait=$3; shift 3
  rm -f "$(docs $dev)/debug-status.txt"
  xcrun simctl terminate $dev com.shimku.HealthCopy 2>/dev/null
  xcrun simctl launch $dev com.shimku.HealthCopy -quiet "$@" >/dev/null
  local n=0
  while (( n < wait )); do
    grep -qE "debug-(done|failed)" "$(docs $dev)/debug-status.txt" 2>/dev/null && break
    sleep 1; (( n++ ))
  done
  sleep 1.5
  xcrun simctl io $dev screenshot "$OUT/$name.png" >/dev/null 2>&1 && echo "$name $(cat "$(docs $dev)/debug-status.txt" 2>/dev/null)"
}
if [[ "$1" != "copy" ]]; then
  run $S 1-home 3 -probe
  run $S 2-send 3 -screen send
  run $S 3-send-done 120 -export
  run $T 4-receive-waiting 3 -screen receive
fi
run $T 5-removed 300 -remove
run $T 6-receive-ready 20 -open $PWD/build/source.healthcopy
# Catch the copy part way, then let it finish for the done screen.
rm -f "$(docs $T)/debug-status.txt"; xcrun simctl terminate $T com.shimku.HealthCopy 2>/dev/null
xcrun simctl launch $T com.shimku.HealthCopy -quiet -import $PWD/build/source.healthcopy -again >/dev/null
sleep 12; xcrun simctl io $T screenshot "$OUT/7-copying.png" >/dev/null 2>&1 && echo 7-copying
until grep -qE "debug-(done|failed)" "$(docs $T)/debug-status.txt" 2>/dev/null; do sleep 1; done
sleep 1.5; xcrun simctl io $T screenshot "$OUT/8-done.png" >/dev/null 2>&1 && echo "8-done $(cat "$(docs $T)/debug-status.txt")"
