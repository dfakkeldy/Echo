# WS1: Identity & macOS Foundation — Implementation Plan

**Goal:** Complete the transition of all external configuration files and package bundle references from the old brand `orbit` to `echo`, share the user-specific macOS scheme so it is version-controlled and visible to CI, and verify that the macOS target builds and executes correctly within its sandbox.

---

## Proposed Changes

### Fastlane and Packaging Configuration

#### [MODIFY] [Appfile](file:///Users/dfakkeldy/Developer/Echo/fastlane/Appfile)
Update all bundle identifiers from `com.orbit.*` to `com.echo.*` equivalents:
* Main bundle ID: `com.echo.audiobooks`
* WatchKit app bundle ID: `com.echo.audiobooks.watchkitapp`
* Widget Extension bundle ID: `com.echo.audiobooks.watchkitapp.widget`
* macOS app bundle ID: `com.echo.audiobooks.macos`

#### [MODIFY] [Fastfile](file:///Users/dfakkeldy/Developer/Echo/fastlane/Fastfile)
* Update `app_identifier` arrays in both iOS and macOS lanes to use the rebranded `com.echo.*` bundle IDs.

#### [MODIFY] [Matchfile](file:///Users/dfakkeldy/Developer/Echo/fastlane/Matchfile)
* Update `git_url` to reference `echo-audiobooks-certificates.git` instead of `orbit-audiobooks-certificates.git`.

#### [MODIFY] [.env.example](file:///Users/dfakkeldy/Developer/Echo/.env.example)
* Rebrand header comment and Match descriptions to read `Echo Audiobooks` instead of `Orbit Audiobooks`.

#### [MODIFY] [transcription_generator.py](file:///Users/dfakkeldy/Developer/Echo/Tools/transcription_generator.py)
* Rebrand comments and descriptions referencing `Orbit Audiobooks` to `Echo Audiobooks`.

---

### Xcode Scheme Configuration

#### [NEW] [Echo macOS.xcscheme](file:///Users/dfakkeldy/Developer/Echo/Echo.xcodeproj/xcshareddata/xcschemes/Echo%20macOS.xcscheme)
* Share the `Echo macOS` scheme to make it visible to version control and future CI runners.
* Copy the structure of [Echo.xcscheme](file:///Users/dfakkeldy/Developer/Echo/Echo.xcodeproj/xcshareddata/xcschemes/Echo.xcscheme) but set the build target and run action target to the `Echo macOS` blueprint ID (`AA0100000000000000000020`), building `Echo macOS.app`.

---

## Verification Plan

### Automated Verification
* Run Fastlane lane verification:
  ```bash
  fastlane test_auth
  ```
* Perform a clean build of the macOS target to confirm it compiles successfully:
  ```bash
  xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS,arch=arm64'
  ```

### Manual Verification
* Launch the macOS application on the local developer machine to confirm that it loads without sandboxing violations or signing runtime crash loops.
* Check that files can be loaded into the reader tab under security-scoped bookmark sandbox constraints.
