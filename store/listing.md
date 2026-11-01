# App Store listing (draft)

Name: Hëlth Transfer
Subtitle: Private Health data transfer
Category: Health & Fitness (second: Utilities)
Price: $0.99 (no in-app purchases)
Age rating: 4+ (answer None or No to every question)
App Privacy: Data Not Collected
Support URL: https://helthtransfer.com/help
Marketing URL: https://helthtransfer.com
Privacy policy URL: https://helthtransfer.com/privacy
Terms of use URL: https://helthtransfer.com/terms (License Agreement in App Store Connect stays Apple's standard one; the terms page builds on it)
Copyright: 2026 Nikita Shimkus

The name on the iPhone home screen stays Hëlth. The App Store name has to be unique, and
"Hëlth Transfer" matches the domain. Name and subtitle words are searched, so the keywords below
don't repeat them.

## Promotional text (170 max, can change any time without review)

Health data didn't come across to your new iPhone? Hëlth copies it straight over by AirDrop. No account, no servers, and nothing is collected.

## Description

Hëlth copies your Apple Health data from one iPhone to another, by AirDrop. There's no account and no server in between, and Hëlth collects nothing. It doesn't even connect to the internet.

It's for when your Health history didn't come with you: iCloud never synced it, you set up a new iPhone without restoring a backup, or you're going back to an older iPhone.

TWO WAYS TO DO IT

With Hëlth on both iPhones:
1. On the iPhone with the data, open Hëlth and tap Send. Your Health data goes into one file.
2. AirDrop the file to the other iPhone. It opens in Hëlth.
3. Tap Copy into Health.

With Hëlth on one iPhone:
If the iPhone with the data can't have Hëlth (a work phone, say), use the Health app there instead: tap your picture, then Export All Health Data. AirDrop export.zip to the iPhone with Hëlth and open it.

WHAT COMES ACROSS
Steps, distance, active energy, heart rate, heart rate variability, sleep, workouts with their routes, weight and body measurements, blood pressure, blood oxygen, nutrition and water, cycle tracking, symptoms, mindful minutes, heartbeat series, State of Mind and more. Each record keeps its dates, values and details, including the device that recorded it, such as your Apple Watch.

NOTHING IS COPIED TWICE
Before anything is copied, Hëlth shows what's in the file and how much. Anything already on the receiving iPhone is skipped, so it's safe to run again. If the copy stops part way, it carries on where it left off. If you change your mind, Remove what Hëlth added takes out what Hëlth copied in and nothing else.

PRIVACY
- No account or sign-in.
- No servers. Hëlth has no internet code at all.
- No analytics, ads or tracking.
- The file goes only where you send it, and Hëlth keeps its own copy out of iCloud backups.
- Privacy label: Data Not Collected.

WHAT APPLE DOESN'T LET APPS COPY
Some Health data can only be written by Apple: Exercise, Stand and Move minutes, Activity rings, ECG recordings, heart rhythm notifications, walking steadiness and wrist temperature, among others. Your Apple Watch records them again once it's paired with the other iPhone. Copied records show Hëlth as their source in the Health app.

Hëlth works with Apple Health. It uses HealthKit only to read and write your Health data, with your permission. Hëlth isn't made by Apple.

One price. No subscription.

## Keywords (100 max)

move,copy,new phone,airdrop,export,import,restore,steps,sleep,workouts,heart rate,history,migrate

## Screenshots

store/screenshots/1-6.jpg, 1320 x 2868 (the 6.9" iPhone slot, the only one needed: the app is
iPhone only and App Store Connect scales them down for smaller iPhones). Captions are in
store/frame.html. To redo them after an app change or a new icon:

    store/capture.sh     raw screens from the HC Source / HC Target simulators (about 4 minutes)
    store/capture.sh duo the same on the iPhone Duo simulator's inner display (unfold it first)
    store/compose.sh     frames and captions, the Duo set, the header and the search artwork

iPhone Duo: store/screenshots-duo/1-6.jpg, 2853 x 2007 (the inner display, open, landscape;
the Duo slot takes outer or inner sizes). Same captions. Apple requires Duo screenshots from
April 2027, and the product page shows an "optimized for iPhone Duo" badge once they're there.
Build 5 is built with the iOS 27.1 SDK, so it fills both Duo displays.

Product page header: store/header.jpg, 3840 x 1646 (21:9). Search results: store/search.jpg,
3840 x 2560 (3:2). Both are drawn by store/art.html. Apple's template keeps the important part
inside a centred safe area (header 1646 x 661, search 2168 x 1030), because each device crops
them differently; art.html?k=header&guides=1 shows it. The header's two phones only show where
it's shown wide. Check both in App Store Connect's preview tool before submitting.

Search results video: store/search.mp4, 1920 x 1280, 10 s loop at 30 fps, H.264 with a silent stereo
AAC track (search plays it muted). Same layout as search.jpg: tap Send, the file crosses to the
other iPhone, tap Copy into Health, Done. store/tools/film.swift records art.html?k=search&anim=1
one WebKit snapshot per frame. search.jpg is the still version, if you'd rather not use video.

Header video: store/header.mp4, 3840 x 1646 (21:9, the only size Apple takes for header video), the
same 10 s loop. The file flies across above the line, inside the safe area, so the motion shows
on every crop; the line sits a little lower than in header.jpg to make room.

The icon's source is store/icon-source.jpg (1024 x 1024, no transparency). The app icon, the logo
on the home screen (Logo.imageset, 216 px) and the site's icon-180.png and icon-64.png are
resized copies of it, made with sips.

## App Review notes

Hëlth copies Health data from one iPhone to another. It has no account, no server and no
network code.

To try it on one iPhone:
1. In Safari on the review iPhone, open https://helthtransfer.com/review/sample-export.zip and
   download it. It's a small Health app export with two weeks of made-up data.
2. Open Hëlth, tap Receive on this iPhone, tap Choose the file and pick sample-export.zip in
   Downloads.
3. Tap Copy into Health, then turn on all categories and allow. The done screen shows what was
   copied, and the records appear in the Health app with Hëlth as their source.
4. To take the sample data out again, tap Remove what Hëlth added on the home screen.

Send (on the iPhone with the data) asks for read access, writes the Health data into a
.healthcopy file and opens the share sheet so the person can AirDrop it to their other iPhone,
where it opens in Hëlth.

HealthKit: read access is used by Send to make the file and by Receive to skip records that are
already there; write access is used by Receive to copy the file's records in. Nothing is sent
anywhere by the app, and nothing is stored in iCloud.

## App Store Connect checklist

Once per account (Business section):
- Paid Apps Agreement, with bank account and tax forms. Paid apps can't go live until it's active.
- App Store Small Business Program: apply, so Apple takes 15% instead of 30%.
- EU trader status (Digital Services Act). Selling a paid app makes you a trader, and Apple then
  shows your address, phone number and email on the EU product page. If you don't want your
  home address public, use a business address, or leave the EU countries out under Availability.

For this app:
- Build 5 (uploaded 31 Oct 2026) is the one to submit: it has the privacy policy link Apple
  requires inside the app (guideline 5.1.1) and keeps Hëlth's files out of iCloud backups.
- App Privacy: "No, we do not collect data from this app."
- Age rating: None or No to everything, which gives 4+. The app has no medical or wellness
  content, it only moves data.
- Pricing: $0.99. Availability: all countries, unless you leave out the EU (see above).
- Content rights: no third-party content.
- Export compliance is already answered in the build (ITSAppUsesNonExemptEncryption = NO), so
  there is no encryption documentation to upload. The only crypto in the app is SHA-256 hashing
  for stable record IDs, which isn't encryption; AirDrop's encryption is part of iOS.
- Sign-in required: no.
- App Review contact: your name, phone and email (not shown publicly).
- The website and support@helthtransfer.com have to work before you submit: the reviewer opens
  the support and privacy links and downloads the sample.

Things Apple may push back on:
- The name. Guideline 5.2.5 asks apps not to look confusingly like Apple's own apps, and Hëlth is
  pronounced like Health. "Hëlth Transfer" and the green icon (Apple's is white with a pink
  heart) keep it clear, and the app's accent is the icon's green now, not pink. If they object,
  a fallback is "Helth Transfer" or a different name entirely.
