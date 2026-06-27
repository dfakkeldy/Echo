# Xcode Archive Privacy Report

Date: 2026-06-27

Archive: `/tmp/EchoPrivacyArchive.xcarchive`

Xcode: 26.6, build 17F113

Command:

```bash
xcodebuild archive \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/EchoPrivacyArchive.xcarchive \
  CODE_SIGNING_ALLOWED=NO \
  -jobs 5
```

## Result

The archive completed successfully. `/tmp/EchoPrivacyArchive.log` reports `** ARCHIVE SUCCEEDED **`.

Archive metadata:

- Scheme: `Echo`
- Product: `Applications/Echo.app`
- Bundle ID: `com.echo.audiobooks`
- Version: `0.6`
- Build: `9`
- Architectures: `arm64`
- Creation date: `2026-06-27 02:21:59 +0000`

## Report Scope

Xcode 26.6 on this machine does not expose a scriptable privacy-report exporter:

- `xcrun --find privacyreport` fails because no developer tool is installed under that name.
- `xcrun --find privacytool` fails because no developer tool is installed under that name.
- `xcodebuild -help` lists archive and export actions, but no privacy report action or export option.
- A targeted search under `/Applications/Xcode.app/Contents` found no privacy-report generator.

This report records the privacy-manifest evidence from the Xcode-produced archive and the archive log's manifest scan, so Task 5.5 can be verified from source-controlled evidence rather than a hand-maintained manifest expectation alone.

## Xcode Archive Scan Evidence

The archive log shows Xcode copying privacy manifests into the archive for the app, watch app, widget extension, and package resource bundles. The final app `Info.plist` processing invoked `builtin-infoPlistUtility` with `-scanforprivacyfile` for these embedded products:

- `Echo Watch App.app`
- `onnxruntime.framework`
- `GRDB_GRDB.bundle`
- `ZIPFoundation_ZIPFoundation.bundle`
- `swift-crypto_Crypto.bundle`
- `swift-transformers_Hub.bundle`

## Archive Manifest Inventory

The archive contains these privacy manifests:

- `Echo.app/PrivacyInfo.xcprivacy`
- `Echo.app/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy`
- `Echo.app/ZIPFoundation_ZIPFoundation.bundle/PrivacyInfo.xcprivacy`
- `Echo.app/swift-crypto_Crypto.bundle/PrivacyInfo.xcprivacy`
- `Echo.app/Watch/Echo Watch App.app/PrivacyInfo.xcprivacy`
- `Echo.app/Watch/Echo Watch App.app/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy`
- `Echo.app/Watch/Echo Watch App.app/PlugIns/Echo WidgetExtension.appex/PrivacyInfo.xcprivacy`
- `Echo.app/Watch/Echo Watch App.app/PlugIns/Echo WidgetExtension.appex/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy`

## Manifest Summary

App targets:

- `Echo.app`, `Echo Watch App.app`, and `Echo WidgetExtension.appex` declare no tracking, no tracking domains, and no collected data types.
- Each app target declares `NSPrivacyAccessedAPICategoryUserDefaults` with reasons `CA92.1` and `1C8F.1`.

Embedded package bundles:

- `GRDB_GRDB.bundle` declares no tracking, no tracking domains, no collected data types, and no required-reason accessed APIs.
- `swift-crypto_Crypto.bundle` declares no tracking, no tracking domains, no collected data types, and no required-reason accessed APIs.
- `ZIPFoundation_ZIPFoundation.bundle` declares no tracking, no tracking domains, no collected data types, and declares `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `0A2A.1`.

## Task 5.5 Conclusion

The Xcode 26.6 archive validation path scanned the archived app and embedded products for privacy manifests, and the archived manifests match the current Task 5.5 decision: the app's broad file metadata access was removed, the app manifests do not need an added file-metadata required-reason category, and dependency-declared required-reason APIs remain represented by their embedded package manifests.
