# Hëlth

Copies Apple Health data from one iPhone to another. On the phone that has the data, Send reads
Health into one `.healthcopy` file; AirDrop it; on the other phone, Receive writes it into Health,
skipping anything that's already there. Nothing goes over the network: the app has no networking
code at all, no analytics and no third-party code. [helthtransfer.com](https://helthtransfer.com)
has the help and the [privacy policy](https://helthtransfer.com/privacy). The Xcode project still
uses the working name, HealthCopy.

When the phone with the data can't have the app, Receive takes the export the Health app itself
makes instead (profile > Export All Health Data): `export.zip`, the unzipped folder, or
`export.xml`. The home screen shows both ways. `HealthCopy/Import/AppleExport.swift` reads it
and turns it into a `.healthcopy` file on the phone, then the copy runs as usual, matching what's
already there to the second (the export has no sub-second times, six-digit values and no UUIDs).

- `scripts/build.sh` builds for the simulator and prints only diagnostics.
- `scripts/roundtrip.sh` runs the whole flow across the "HC Source" and "HC Target" simulators
  (a UI test answers Health's permission screen) and compares the target with the source file
  record by record (`scripts/compare`).
- `scripts/apple-roundtrip.sh export.zip truth.healthcopy` does the same for Apple's export: the
  `HealthAppExport` UI test makes a real export.zip with the simulator's Health app, Send makes the
  truth from the same phone, and `scripts/applecompare` checks the target against it.
- `scripts/appleexport` converts an export on the Mac with the app's own code;
  `scripts/gen/enums.py` regenerates `AppleNames.swift` from the SDK's HealthKit headers.
- `scripts/upload.sh <build>` archives and uploads to App Store Connect for TestFlight.
- `store/` has the App Store listing (`listing.md`) and what the store art is made from:
  `store/capture.sh` takes the raw screens from the simulators, and `store/compose.sh` renders the
  screenshots (iPhone and iPhone Duo), the header and search art and their videos (not in git).
  The website is its own repo.

What can't be copied is Apple's rule, not this app's: apps can't write Exercise, Stand or Move
minutes, heart rhythm notifications, walking steadiness or asymmetry, wrist temperature, AFib
history, breathing disturbances or the cycle deviation alerts, and every copied record shows
Hëlth as its source (the original device is kept).
