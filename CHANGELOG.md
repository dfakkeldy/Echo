# Changelog

## Unreleased

- Relicensed project from GPL-3.0 to MIT.
- Major project cleanup: removed legacy `BookLoop` / `LoopPlayer` projects, orphaned watch target, redundant icons, and junk files.
- Renamed legacy `BookLoop*`-named Swift files to match the `Orbit Audiobooks` target.
- Reorganized each target into MVVM folders (`Views`, `ViewModels`, `Models`, `Services`).
- Updated `.gitignore` with comprehensive Swift/Xcode rules (DerivedData, xcuserdata, SPM, CocoaPods, Carthage, Fastlane).
