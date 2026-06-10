fastlane documentation
----

> **⚠️ Echo rebrand note:** Bundle IDs currently use `com.echo.audiobooks.*` to match the Xcode project. These will be migrated to `com.echo.audiobooks.*` during the Phase 8 rebrand. See `ROADMAP.md` for details.

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Archive and upload to TestFlight.

This lane:
1. Syncs code signing via match (appstore) for all bundle IDs
2. Archives the iOS target (includes bundled watchOS app + widget)
3. Archives the macOS target (if a macOS scheme exists)
4. Uploads all resulting .ipa / .pkg files to TestFlight

Prerequisites:
- fastlane match set up with a git repo and MATCH_PASSWORD
- App Store Connect API key JSON at fastlane/api_key.json


### ios test_auth

```sh
[bundle exec] fastlane ios test_auth
```



----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
