#!/bin/zsh
# Builds the app (and UI tests) for the simulator; prints only diagnostics.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "${0:A:h}/.."
source scripts/.sims
xcodebuild -project HealthCopy.xcodeproj -scheme HealthCopy -configuration Debug -sdk iphonesimulator \
  -destination "id=$S" -derivedDataPath build/dd ${1:-build} 2>&1 \
  | grep -E "^/.*(error|warning):|BUILD (SUCCEEDED|FAILED)|\*\* TEST" | grep -v "icon-1024" | sort -u
