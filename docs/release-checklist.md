# Echo App Store preparation checklist

Re-checked: 2026-10-06. This is a preparation checklist, not a readiness receipt.
Store declarations, prices and agreements remain owner decisions. Track private
audit results separately; keep contacts, tester identities, credentials and
private book content out of this public repository.

## Candidate and promotion gates

- Record exact SHA and version/build for iOS with embedded Watch/widget and the
  separately packaged Mac app. The checked-in `0.6` / build `9` is configuration;
  `beta` overrides the build number at archive time.
- Keep internal nightly → external weekly → main App Store promotion. Verify
  current branch protection and actual completed CI jobs at the selected head.
  A docs-only check can skip Xcode, and a green release run can omit Mac after a
  warning or skip all uploads when credentials are unavailable.
- Record iOS and Mac upload/processing receipts separately. Check external
  eligibility, Beta App Review and installation before calling weekly accepted.
  TestFlight approval is separate from App Store approval or availability.
- Run one heavy Apple build/capture operation at a time. Test the actual release
  candidate's import → play → background/lock-screen → resume journey and the
  Watch controls. Investigate reported narration failures on supported devices;
  older engine benchmarks or short smoke tests do not clear a current report.

## Store materials

- Confirm name/subtitle, description, keywords, promotional text, categories,
  copyright and support/privacy URLs against the selected build. Name/subtitle
  limits are 30 characters, description 4,000, promotional text 170, keywords
  100 bytes. What's New applies to updates, not the first store version.
- Verify support contact and privacy policy are accessible to a reviewer and
  privacy is linked in the app. Explain optional AI-provider transmission,
  personal iCloud sync, Audiobookshelf connections and model downloads precisely;
  avoid an absolute “everything stays on-device” claim.
- Follow [the capture guide](../fastlane/screenshots/en-US/README_SCREENSHOTS.md)
  for real iPhone, iPad, Watch and Mac UI. Current Apple specs require the medium
  Dynamic Island iPhone category, 13-inch iPad when supported, Watch screenshots
  for the Watch app, and 16:10 Mac images. Verify actual ASC category acceptance.
  Do not use concept mockups or private book covers/content as store screenshots.
- Supply reproducible review steps using rights-cleared content, optional
  service setup and the actual purchase state. Echo core import/playback does not
  require an Echo account. An optional Audiobookshelf login is user-managed;
  store demo credentials only in the authorized review interface if needed.

## Configuration and declarations

- Reconcile all four source privacy manifests, required-reason API use and
  dependency manifests/signatures with the exact archive's privacy report.
  Empty collected-data arrays do not prove ASC “No Data Collected.”
- Check release entitlements and provisioning without inspecting or changing
  credentials: App Groups, iOS/Mac CloudKit, Mac sandbox/network/user-selected
  files and bookmarks, iOS/Watch audio background mode. No CarPlay entitlement is
  configured; do not promise CarPlay support from dormant source alone.
- Source sets `ITSAppUsesNonExemptEncryption=NO`; owner confirmation of the
  export-compliance determination and applicable territory obligations remains
  separate. Review Content Rights, current age and social-media questionnaires,
  territory availability, DSA trader status and current agreements in ASC.
- Weekly/nightly configure only `com.echo.pro.unlock` and
  `com.echo.pro.founders` as non-consumables and currently enable a temporary
  `paywallDisabled` bypass. Verify the selected branch, reachable UI, live product
  states and commercial intent before describing Pro as purchasable. Source
  purchase/restore code is not a sandbox transaction receipt. Do not create
  subscriptions or enable charging from an older plan without authorization.
- When account creation is introduced, provide in-app account deletion. An
  Apple-managed iCloud identity alone is not an Echo-created account; audit any
  future registration paths before treating deletion as not applicable.

## Evidence to retain

Exact source → release toolchain/archive → tests → upload/processing → external
beta state → device acceptance → selected store version/review → release setting
and territory availability. Record unknowns rather than filling them from old
builds. Present the owner's remaining decisions in one consolidated handoff.

## Official Apple references

- [Upcoming submission requirements](https://developer.apple.com/news/upcoming-requirements/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Account deletion](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion)
- [Configure IAP for review](https://developer.apple.com/help/app-review/before-submitting-for-review/configure-in-app-purchases)
- [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [DSA trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)
- [App and submission statuses](https://developer.apple.com/help/app-store-connect/reference/app-information/app-and-submission-statuses)

## October 6 preparation evidence

A text-only book imported from a long folder URL reached model-ready and first
synthesis, then failed to create its cache audio file in an isolated iOS
simulator. The URL-derived cache prefix exceeded the filesystem's 255-byte
component limit. A real partial-file creation regression failed with file-name-
too-long before the repair. Long UTF-8 prefixes now use a stable hash of the
original identity; ordinary short cache names, audio format, render version,
track identity and pronunciation policy are unchanged.

All 46 focused naming, actual lossless writer, streaming, cache-cleanup and
export tests passed locally. Existing long-prefix caches that previously fit
remain on disk but need regeneration for new-prefix discovery; no cache wipe
or destructive migration occurs. Verify the same input's actual render and
playback completion separately, then the selected signed device. This simulator
finding does not establish the cause of a physical-phone completion report.
