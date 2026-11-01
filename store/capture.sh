#!/bin/zsh
# Captures the raw app screens for the App Store screenshots and the website, from the test
# simulators (which already have Health access and data). Then run store/compose.sh.
#   store/capture.sh          (builds first; takes about four minutes)
#   store/capture.sh duo      the same screens on the iPhone Duo simulator's inner display, into
#                             store/raw-duo. Unfold the Duo in Device Hub first: folded, the inner
#                             display is off and the screenshots come out black. It plays both
#                             phones, so it gets Health access and fresh full data first.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
source scripts/.sims
scripts/build.sh | grep -v "BUILD SUCCEEDED"
APP=build/dd/Build/Products/Debug-iphonesimulator/HealthCopy.app
OUT=store/raw SHOT=()
if [[ $1 == duo ]]; then
  export DUO=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone Duo/ {print $2; exit}')
  S=$DUO T=$DUO OUT=store/raw-duo SHOT=(--display=internal)
fi
mkdir -p $OUT
for d in $S $T; do
  xcrun simctl boot $d 2>/dev/null
  xcrun simctl ui $d appearance light
  xcrun simctl status_bar $d override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 --operatorName ""
  xcrun simctl install $d $APP
done
# Seeding isn't safe to repeat, so clear what Hëlth added first. Send asks to read more kinds than
# seeding does, so one export answers that permission screen too.
[[ $1 == duo ]] && scripts/run.sh DUO "-remove" && scripts/run.sh DUO "-seed full" && scripts/run.sh DUO "-export"
container() { xcrun simctl get_app_container $1 com.shimku.HealthCopy data }
# run DEVICE NAME WAIT ARGS...: launch, wait for the debug action (or WAIT seconds), screenshot.
# NAME "-" skips the screenshot.
run() {
  local dev=$1 name=$2 wait=$3; shift 3
  local st="$(container $dev)/Documents/debug-status.txt"
  rm -f "$st"
  xcrun simctl terminate $dev com.shimku.HealthCopy 2>/dev/null
  xcrun simctl launch $dev com.shimku.HealthCopy -quiet "$@" >/dev/null
  local n=0
  while (( n < wait )); do
    grep -qE "debug-(done|failed)" "$st" 2>/dev/null && break
    sleep 1; (( n++ ))
  done
  sleep 2
  [[ $name == - ]] || xcrun simctl io $dev screenshot $SHOT "$OUT/$name.png" >/dev/null 2>&1
  echo "$name $(cat "$st" 2>/dev/null)"
}

# The receiving phone starts with no file, so Receive shows its waiting screen.
find "$(container $T)/Library/Application Support/HealthCopy" \( -path "*/Incoming/*" -o -name "import-*.json" \) -delete 2>/dev/null
run $T home 3
run $T home-health-app 3 -healthapp
run $T home-privacy 3 -privacy
run $T receive-waiting 3 -screen receive
run $S send-done 180 -export
# A few days already on the receiving phone, so the done screen shows what was skipped.
run $T - 400 -remove
run $T - 120 -seed partial
run $T receive-plan 60 -open $PWD/build/source.healthcopy
run $T receive-done 600 -import $PWD/build/source.healthcopy
run $T receive-export 120 -open $PWD/build/apple/export.zip
