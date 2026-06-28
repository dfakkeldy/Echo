# Settings Cleanup Design

## Context

Echo's settings are currently split across a native `Form` surface and several custom
`ScrollView` designer screens. The result is hard to scan: root Settings groups some
items by implementation detail, "Customization" acts as a catch-all, and related
phone/watch/player controls use different row styles and labels.

The cleanup should use the current `origin/nightly` settings surface as the source
of truth. This worktree was originally detached at `origin/main`, but `nightly`
contains newer Settings, Study, Support, Feedback, Context Memory, and watch-slot
fallback work.

## Goals

1. Make all settings feel like one coherent system.
2. Arrange root Settings into logical user-intent sections.
3. Normalize control styles across Phone Player Settings, Watch App Settings, and
   Playback Options.
4. Fix watch defaults for new installs or unset app-group keys:
   - Classic watch face is the default.
   - Circular ring represents book progress by default.
   - Linear bar represents chapter progress by default.
5. Replace the watch progress menu pickers with clearer segmented controls.
6. Update help/documentation paths so user-facing guidance matches the new IA.

## Non-Goals

1. Do not migrate or overwrite existing users' saved watch face/progress choices.
2. Do not redesign the playback UI, watch runtime UI, bottom chrome, or player
   layouts beyond the settings surfaces needed for this cleanup.
3. Do not raise deployment targets, Swift language version, or add dependencies as
   part of this work.
4. Do not remove the custom phone/watch preview canvases; they are useful where the
   user is directly designing controls.

## Current Project Constraints

- Xcode detected in this worktree: Xcode 26.6.
- Project file currently reports `IPHONEOS_DEPLOYMENT_TARGET = 18.0`,
  `WATCHOS_DEPLOYMENT_TARGET = 11.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`, and
  `SWIFT_VERSION = 5.0`.
- Preserve the current platform support unless a separate migration explicitly
  changes it.
- Use SwiftUI and the existing `@MainActor @Observable SettingsManager` pattern.
- Do not introduce third-party frameworks.
- Echo feature/docs PRs should target `nightly`.

## Information Architecture

Root Settings should group preferences by user intent:

- **Now Playing**
  - Playback Options entry
  - Smart Rewind
  - default playback speed for new books
  - skip backward and skip forward duration defaults
  - play bookmarks inline

- **Appearance**
  - app color scheme
  - app icon
  - accent color
  - app font
  - reader display defaults
  - chapter-name truncation

- **Controls**
  - Phone Player Settings
  - Watch App Settings
  - mini-player buttons
  - control presets and designer-related entries
  - focus tools that are controlled from the player, such as Soundscape and
    Interval Chime

- **Library & Accounts**
  - Audiobookshelf connections
  - Echo Pro status/purchase/restore

- **Study & Notes**
  - flashcard deck import
  - global new chapter limit
  - study-note export
  - future spaced-repetition controls

- **Advanced & Privacy**
  - continuous auto-alignment
  - context memory/location capture
  - delete context memory
  - debug-only developer tools when applicable

- **Support & About**
  - feedback and support
  - help
  - privacy policy
  - version/build metadata

## Shared Presentation Rules

Use native `Form` and `Section` rows for ordinary preferences. This gives settings a
consistent system feel, supports accessibility and Dynamic Type better, and avoids
the current card-on-card look.

Custom preview cards remain appropriate for the actual designer canvases:

- phone player button preview
- watch face/page preview
- action palette chips used for drag-and-drop

Controls should follow the same vocabulary everywhere:

- segmented pickers for short mutually-exclusive options with 2-4 choices
- menu pickers for longer slot/action lists
- toggles for binary settings
- `InlineStepperRow` or native stepper rows for numeric values
- native `NavigationLink` rows for drill-down settings
- consistent section labels: "Available Actions", "Presets", "Layout", "Progress"

## Watch App Settings

Watch settings should separate ordinary preferences from the layout designer.

### Face

- Face Style: `Classic` and `Full Face`
- Classic Background: `Blurred` and `Black`
- Scroll Title toggle and speed when enabled
- Show Date toggle and date format when enabled

Default for `SettingsManager.Defaults.watchArtworkLayout` should become
`"classic"`. Existing persisted values must remain untouched.

### Progress

Progress rows should explain what each indicator represents:

- Circular Ring: `Book` / `Chapter`
- Linear Bar: `Chapter` / `Book`
- Show Circular Ring toggle
- Show Linear Bar toggle

Implementation mapping:

- `Book` writes `"total"`
- `Chapter` writes `"chapter"`
- default circular ring mode becomes `"total"`
- default linear bar mode becomes `"chapter"`

The segmented controls should replace the current `.menu` pickers because each
indicator has only two choices and the selected meaning should be visible without
opening a menu.

### Controls

- Digital Crown mode
- crown volume sensitivity
- crown scrubbing sensitivity
- button haptics
- quick bookmark timeout

### Layout Designer

Keep the current watch preview and five-page designer, but normalize surrounding
labels and fallback controls:

- page selector and page count
- slot pickers as a non-drag fallback
- "Available Actions" palette
- "Presets" section
- "Sync Now" action

The designer may keep a custom surface because it is visual and task-specific.

## Phone Player Settings

Phone Player Settings should become the durable control-design screen.

Sections:

- **Layout**
  - player layout style (`Default` / `Compact`)

- **Mini-Player**
  - three mini-player button slot pickers

- **Player Buttons**
  - tap/long-press segmented mode
  - existing preview canvas
  - slot pickers as a non-drag fallback
  - "Available Actions" palette

- **Focus Tools**
  - Soundscape
  - Interval Chime

- **Presets**
  - saved layouts
  - load/delete affordances
  - reset defaults

Phone and watch designers should share language where possible: "Available
Actions", "Presets", "Slot 1", "Slot 2", and "Reset to Defaults" should not vary
without a reason.

## Playback Options

Playback Options should remain the fast in-context sheet for settings that affect
the current listening session.

Sections:

- Speed
- Loop
- Skip
  - Skip Backward
  - Skip Forward
  - Smart Rewind
- Volume Boost
- More Controls link into Phone Player Settings

The sheet should not be the only practical route to durable phone-control settings.
Root Settings should also expose the durable controls home.

## Advanced, Study, Library, And Support

Advanced & Privacy owns settings whose consequences are technical, privacy-related,
or harder to explain in a playback surface:

- continuous auto-alignment
- context memory/location capture
- delete context memory
- debug-only silence detection/development tools

Study & Notes owns learning workflow settings and actions:

- deck import
- global new chapter limit
- all study-note export

Library & Accounts owns external services and commercial/account state:

- Audiobookshelf connections
- Echo Pro status, purchase, restore

Support & About owns help and diagnostics:

- feedback and support
- help
- privacy policy
- version and commit metadata

## Help And Documentation Updates

Update stale settings paths in help/docs after the IA changes. Known candidates on
`origin/nightly` include:

- `Settings > Phone Controls`
- `Settings > Playback > Default Speed`
- `Settings > Smart Rewind`
- `Settings > Watch App`
- `Settings > Customization > Phone Player Designer > Player Layout Style`

Documentation should describe user-visible paths, not implementation names.

## Data And Sync Behavior

`SettingsManager` remains the source of truth for settings defaults and persistence.
Watch-facing settings continue to write through app-group defaults so the watch and
widget can read them.

Changing defaults affects only new installs and keys that have no persisted value.
Do not add a migration that rewrites existing app-group values for:

- `watchArtworkLayout`
- `linearBarMode`
- `circularRingMode`
- visibility toggles

After watch settings change, continue calling `model.syncToWatch()` from the same
state-change boundaries so the watch receives updates promptly.

## Testing

At minimum, implementation should add or update tests for:

- `SettingsManager.Defaults.watchArtworkLayout == "classic"`
- `SettingsManager.Defaults.linearBarMode == "chapter"`
- `SettingsManager.Defaults.circularRingMode == "total"`
- registered app-group defaults for the watch values
- persisted app-group values still overriding defaults
- watch context pass-through for progress and face settings

If reusable settings helpers are extracted, cover them with focused tests where they
contain logic. Pure SwiftUI layout extraction does not need unit tests unless it
changes behavior.

## Acceptance Criteria

1. Root Settings sections match the approved IA.
2. Watch App Settings uses consistent settings rows for non-designer preferences.
3. Watch progress controls are segmented and clearly labeled by meaning.
4. New watch defaults are classic face, ring book progress, bar chapter progress.
5. Phone Player Settings and Watch App Settings use matching designer terminology.
6. Playback Options remains quick and session-oriented.
7. Help/docs paths match the new Settings IA.
8. Existing user preferences are preserved.
9. Relevant tests pass.
