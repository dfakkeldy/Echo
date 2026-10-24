# Platform verification

Reviewed against the shared schemes and CI on October 24, 2026. A scheme's name
does not tell you which suites its Test action selects. On the shared development
Mac, run agent-started Apple builds/tests through the build-slot wrapper required
by your working instructions.

For the normal unit-test loop use `make test`, or `make build-tests` followed by
`make test-only FILTER=EchoTests/TOCTreeBuilderTests`. The shared Echo scheme has
both `EchoTests` and `EchoUITests` in its Test action; the Makefile and hosted CI
explicitly select only `EchoTests`. A bare scheme-wide Test also selects UI tests.

For a direct unit-only command, select an installed simulator first (the model
names below are examples, not an assurance that those destinations are installed):

```sh
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:EchoTests \
  -parallel-testing-enabled NO \
  -jobs 5 \
  CODE_SIGNING_ALLOWED=NO
```

The Mac scheme's Test action selects `MisakiSwiftTests`, not an app-wide Mac
integration suite. Use a separate build action when compilation is the result
you need. Build the Release CLI with `make echo-cli` so its required compiler
settings are applied.

```sh
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme "Echo macOS" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -jobs 5 \
  CODE_SIGNING_ALLOWED=NO
```

The WidgetExtension scheme builds the Watch app/widget, but its Test action
selects `Echo Watch AppTests`. It is not a widget-rendering acceptance test. The
widget target is watchOS-only. Hosted CI compile-checks the embedded Watch app;
Watch unit execution is a separate check using an installed Watch destination.

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

`make doc-contract-test doc-automation-test` runs the fast documentation checks
without Xcode. A docs-only CI pass does not prove Apple compilation. Keep suite
results, app builds, installation, TestFlight uploads, and observed device
behavior distinct. See [release verification](release-checklist.md).
