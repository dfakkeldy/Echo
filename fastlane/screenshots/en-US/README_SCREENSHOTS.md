# App Store Screenshots

Two ways to produce the App Store screenshots — both land PNGs in this folder,
ready for `fastlane upload_screenshots` (or any `deliver` run).

## TL;DR

```sh
bundle exec fastlane screenshots        # automated: UI test drives the app
# …or…
Scripts/capture_screenshots.sh          # assisted: you navigate, it captures
```

The five shots we want (from MARKETING.md, captioned by *benefit*, not feature):
① Player ② synced Reader ③ study / flashcards ④ Watch remote ⑤ "all on-device" privacy.

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

### ⚠️ Content seeding (read this — it's why shots may come out empty)

The screens are content-gated: the Reader needs an EPUB, the player needs an
audiobook, etc. In **DEBUG simulator** builds the app auto-seeds a sample on
launch (`EchoCoreApp.init` → `MockMediaProvider.seedSampleAudiobookIfNeeded`,
then `PlayerModel.restoreLastSelectionIfPossible`), **but only if `BIFF.m4b` is
bundled into the Echo app target.** `*.m4b` is git-ignored, so:

1. Add a short sample `BIFF.m4b` to the Echo app target's "Copy Bundle
   Resources" (a bundled EPUB sample already lives in
   `EchoCore/Development Assets/`).
2. Then `fastlane screenshots` will have real content on screen.

Without it, the run still succeeds but content-gated screens show their empty
states — fine for a privacy/settings shot, not for the player. The UI test is
defensive: a missing screen is skipped, never a hard failure.

The test navigates by accessibility **labels** (the app ships no accessibility
identifiers). If you restyle the bottom dock / top header, keep the labels
("Toggle chapters list", "More options", "Settings") in sync or update the test.

---

## Route B — `Scripts/capture_screenshots.sh` (assisted, no app changes)

```sh
Scripts/capture_screenshots.sh                      # iPhone 16 Pro Max, en-US
Scripts/capture_screenshots.sh "iPad Pro 13-inch (M4)"
```

Boots the simulator with the same clean marketing status bar, then captures
whatever is on screen each time you press Enter and type a name — you do the
navigating. Best for the shots that are fiddly to automate (Reader with a real
book open, a staged flashcard review). Build & install the app on that simulator
first (Cmd-R in Xcode). Captures are named and sized correctly automatically.

For **watchOS** and **Mac**, capture by hand for now (watch snapshot automation
is a separate setup): Simulator → File ▸ Save Screen (⌘S), or `xcrun simctl io
booted screenshot`, into this folder using the naming convention below.

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

Apple now requires only the **6.9" iPhone** and **13" iPad** for new
submissions; smaller sizes are derived automatically. Capture the others only if
you want native (non-scaled) art.

| Device | Resolution | Required |
|---|---|---|
| iPhone 16 Pro Max (6.9") | 1320 × 2868 | ✅ |
| iPad Pro 13" | 2064 × 2752 | ✅ |
| iPhone 16 Pro (6.3") | 1206 × 2622 | optional |
| Mac | 2880 × 1800 | for the Mac app |
| Apple Watch Ultra | 410 × 502 | for the Watch app |

## Uploading

```sh
bundle exec fastlane upload_screenshots   # screenshots + metadata, no binary
```

(Requires `fastlane/api_key.json`.) Add device frames first with
`bundle exec fastlane frame_screenshots` (needs `brew install imagemagick`).

## Notes

- Screenshots are git-ignored (`.gitignore` → `fastlane/screenshots/**/*.png`).
  To version-control finals, remove that rule or `git add -f` the chosen PNGs.
- Keep the device list short — this is a 16 GB machine, so `Snapfile` disables
  concurrent simulators (`concurrent_simulators(false)`).
