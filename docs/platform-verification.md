# Platform Verification

Echo's shared schemes are organized around the platform that owns each target.
Use these commands for focused command-line verification:

```sh
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -jobs 5 \
  CODE_SIGNING_ALLOWED=NO
```

```sh
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme "Echo macOS" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -jobs 5 \
  CODE_SIGNING_ALLOWED=NO
```

```sh
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme "Echo WidgetExtension" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' \
  -parallel-testing-enabled NO \
  -jobs 5 \
  CODE_SIGNING_ALLOWED=NO
```

```sh
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme MisakiSwift \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

```sh
cd ThirdParty/MisakiSwift
swift test
```
