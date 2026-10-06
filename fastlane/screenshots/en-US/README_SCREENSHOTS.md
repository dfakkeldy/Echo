# App Store Screenshots

Two ways to produce raw App Store screenshots — both land PNGs in this folder.
Review actual UI/content, current Apple dimensions and rights before a separately
authorized `fastlane upload_screenshots` invocation. File presence is not review
acceptance. The fresh repository contained no PNG/JPG finals on 2026-10-06.

## TL;DR

```sh
bundle exec fastlane screenshots        # automated: UI test drives the app
# …or…
Scripts/capture_screenshots.sh          # assisted: you navigate, it captures
```

Prepare benefit captions for features verified on the selected candidate:
① Turn Listening Into Learning ② Read Along With Your Book ③ Capture What
Matters ④ Control Listening On Your Wrist ⑤ Your Books, Your Library.
The study and Watch-review shots need their own acceptance before stronger
flashcard/review claims. Privacy captions must disclose optional external AI,
iCloud and Audiobookshelf connections accurately.

---

## Route A — `fastlane snapshot` (automated)

```sh
bundle exec fastlane screenshots
```

This builds the **Echo Screenshots** scheme and runs the `EchoScreenshots` UI
test (`EchoUITests/EchoScreenshots.swift`) on every device/language listed in
[`fastlane/Snapfile`](../../Snapfile), capturing a PNG per screen with a clean
status bar (9:41, full bars, 100% battery). No App Store Connect key needed.

**How the pieces fit together**
- `fastlane/Snapfile` — device list, language list, scheme, output dir. Edit the
  `devices([...])` list to match `xcrun simctl list devices` on your Mac.
- `Echo.xcodeproj/.../Echo Screenshots.xcscheme` — a shared scheme whose Test
  action runs `EchoUITests` (the default **Echo** scheme deliberately excludes
  UI tests, so snapshot needs its own).
- `EchoUITests/SnapshotHelper.swift` — stock fastlane helper (`setupSnapshot`,
  `snapshot()`).
- `EchoUITests/EchoScreenshots.swift` — the test that launches the app and walks
  Player → Timeline → Reader → Stats → Settings, calling `snapshot(...)` at each.
  Treat those raw captures as source material: the final App Store images should
  be framed and captioned with the benefit-led lines above, not uploaded as plain
  UI captures.

### ⚠️ Content seeding (read this — it's why shots may come out empty)

The screens are content-gated: the Reader needs an EPUB, the player needs an
audiobook, etc. In **DEBUG simulator** builds the app auto-seeds a sample on
launch (`EchoCoreApp.init` → `MockMediaProvider.seedSampleMediaIfNeeded`,
then `PlayerModel.restoreLastSelectionIfPossible`). The automated
`EchoScreenshots` run passes `--echo-screenshot-fixture-gatsby` and
`--echo-screenshot-appearance-dark`, so App Store captures always open the
bundled Standard Ebooks copy of *The Great Gatsby* with Echo's internal
appearance preference set to Dark, even if a local audio sample is present.

For ad-hoc/manual audio-backed captures, you can still bundle a local,
rights-cleared `EchoScreenshotSample.m4b`. `*.m4b` is git-ignored, so the
optional audio path is:

1. Add a short public-domain or otherwise rights-cleared sample named
   `EchoScreenshotSample.m4b` to the Echo app target's "Copy Bundle Resources"
   (bundled EPUB samples already live in `EchoCore/Development Assets/`).
2. Launch the app manually or remove the Gatsby fixture argument if you
   intentionally want audio-backed player content instead of the canonical
   Gatsby EPUB run.

The UI test checks that its five capture names were produced. It does not prove
that the intended screen, populated content or study interaction is visible;
inspect every image and recapture incorrect screens before upload.

Recommended local fixture path:

```
fastlane/fixtures/EchoScreenshotSample.m4b
```

Keep fixture media out of git unless it is sanitized and licensed for
redistribution; add it to the Echo target's Copy Bundle Resources locally before
running `fastlane screenshots`.

The test navigates by accessibility **labels** (the app ships no accessibility
identifiers). If you restyle the bottom dock / top header, keep the labels
("Toggle chapters list", "More options", "Settings") in sync or update the test.

---

## Route B — `Scripts/capture_screenshots.sh` (assisted, no app changes)

```sh
Scripts/capture_screenshots.sh "iPhone 17 Pro"         # medium Dynamic Island class
Scripts/capture_screenshots.sh "iPad Pro 13-inch (M5)"
```

Boots the simulator with the same clean marketing status bar, then captures
whatever is on screen each time you press Enter and type a name — you do the
navigating. Best for the shots that are fiddly to automate (Reader with a real
book open, a staged flashcard review). Build & install the app on that simulator
first (Cmd-R in Xcode). Captures are named and sized correctly automatically.

For **watchOS** and **Mac**, capture by hand for now (watch snapshot automation
is a separate setup): Simulator → File ▸ Save Screen (⌘S), or `xcrun simctl io
booted screenshot`, into this folder using the naming convention below.

Manual release checklist:

- iPhone set includes the first three search-result shots: Player/listening,
  synced EPUB reader, and flashcard/study.
- iPad set includes the same first three search-result shots, adapted to the
  larger layout.
- Watch remote shot is captured manually and named with `_Watch`.
- Mac app shot is captured manually and named with `_Mac`.
- Privacy is shown as a visual local-first/on-device frame where possible;
  Settings is supporting evidence, not the preferred final conversion image.
- Any intentionally omitted category is noted in the release notes before upload.

---

## Naming Convention

Numbered prefix (sort order) + descriptive slug + device type:

```
01_Player_iPhone.png
02_Reader_iPhone.png
03_Stats_iPhone.png
01_Player_iPad.png
01_Player_Watch.png
01_Player_Mac.png
```

The automated route names files `<Simulator>-NN_Name.png`; deliver matches them
to the right device by image dimensions regardless of the slug.

## Required Sizes

Re-checked 2026-10-06 against Apple's current
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
The required iPhone category is **medium Dynamic Island**, rather than the old
6.9-inch-only claim. The 13-inch iPad category applies because Echo supports iPad;
Watch and Mac need their own sets. PNG/JPG/JPEG must have no alpha/transparency.
One to ten images per category are allowed; use one consistent Watch size across
localizations. Confirm the accepted category in ASC before declaring a set ready.

| Category | Accepted dimensions | Echo capture plan |
|---|---|---|
| Medium Dynamic Island iPhone | 1179 × 2556 or 1206 × 2622 | Capture a medium device such as iPhone 17 Pro explicitly |
| 13-inch iPad | 2064 × 2752 or 2048 × 2732 | iPad Pro 13-inch |
| Mac, 16:10 | 1280 × 800, 1440 × 900, 2560 × 1600 or 2880 × 1800 | Manual current Mac UI capture |
| Watch | 422 × 514, 410 × 502, 416 × 496, 396 × 484, 368 × 448 or 312 × 390 | Manual paired Watch UI capture |

Landscape reversals apply to iPhone/iPad. Mac requires the listed landscape
16:10 dimensions. The existing Snapfile still prefers
an iPhone Pro Max; it has not been changed by this documentation preparation.
Use the assisted medium-device capture or update the automated capture choice in
a separately reviewed change. Larger assets may use Apple's scaling fallbacks,
but they do not establish acceptance in the required medium category.

## Uploading

```sh
bundle exec fastlane upload_screenshots   # screenshots + metadata, no binary
```

(Requires `fastlane/api_key.json`.) Add device frames first with
`bundle exec fastlane frame_app_store_screenshots` (needs `brew install imagemagick`).

The current release-train workflow does not invoke screenshot or metadata upload.
The `upload_screenshots_if_available` lane can be called separately after review
and authorization. It only checks file presence; it cannot establish that the
images are accurate or rights-cleared. Screenshot capture itself needs no ASC
sign-in.

## Notes

- Screenshots are git-ignored (`.gitignore` → `fastlane/screenshots/**/*.png`).
  To version-control finals, remove that rule or `git add -f` the chosen PNGs.
- Keep the device list short — this is a 16 GB machine, so `Snapfile` disables
  concurrent simulators (`concurrent_simulators(false)`).
