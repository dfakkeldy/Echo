# Echo "Mind" Icon Family — Design

**Date:** 2026-06-27
**Status:** Approved design, pending implementation plan
**Author:** Dan Fakkeldy (with Claude)

## 1. Summary

Replace Echo's app icon identity with a cohesive **gold/silver-on-dark "Mind" family** of
four marks that fuse Echo's existing infinity-loop equity with a brain (study/learning) motif.
A new **Circuit Brain** mark becomes the default across every target; three siblings and the
preserved legacy icons live in the in-app icon picker.

The art is produced by a **repeatable SVG → PNG pipeline** committed to the repo, not by
one-off AI image generation. This makes the icon set *code*: regenerable at any size, diffable,
and tunable, and it directly fixes the standing problem that the current AI-generated icons
"look weird on the phone" because the same detailed 1024px art is naively downscaled to 40px.

## 2. Goals

- Ship a **default icon that signals "study/learning"** (a brain) rather than a bare ∞.
- Keep the **loop + play equity** reachable (one tap away) so the audiobook-player read isn't lost.
- Make every icon **legible at Home-Screen size (40–60px)**, not just at 1024px.
- Establish a **maintainable, reproducible icon pipeline** (SVG masters under version control).
- Achieve **parity across all targets**: iOS, watchOS, macOS, Widget.
- **Preserve everything that exists today** — no current icon is deleted.

## 3. Non-Goals (this pass)

- iOS 18 **dark / tinted** icon appearance variants (deployment target is iOS 18.0, so this is
  available as a fast-follow, but out of scope here).
- Animated / parallax / Live Activity icon treatments.
- App Store marketing renders / screenshots.
- A **thumbnail preview per row** in the picker (nice fast-follow; the picker is text-only today
  and stays text-only here).

## 4. The Family

All marks share: a dark radial-charcoal background, a polished **gold + silver** metal duotone,
and a single dominant silhouette that fills ~70–80% of the tile.

| Slot | Name | Mark | Role |
|------|------|------|------|
| **Primary `AppIcon`** | **Circuit Brain** (D) | Side-profile brain whose folds are gold/silver circuit traces with node dots; a small ∞ is woven into the central gyri | **Default** — study-forward, bold, small-safe |
| Alternate | **Hemisphere ∞** (A) | The current loop reborn: two metal hemispheres forming an ∞, gold play triangle in the right lobe | Brand bridge — keeps loop + "audio" read |
| Alternate | **Top-Down Brain** (B) | Symmetric brain seen from above; central fissure hides an ∞; gold (left) / silver (right) gyri | Most "designed", gallery-quality |
| Alternate | **Brainwave** (C) | Silver ∞ with a gold echo/EEG waveform running through it | Most original / ownable |
| Alternate | **Classic Loop** | The *current* gold/silver ∞-with-play default, preserved verbatim | Safety net so the existing default is never lost |

Legacy alternates retained unchanged: **Complex Waves**, **Gold & Silver**, **Silver & Gold**,
**White Bolder**.

### 4.1 Visual language (reproducible spec)

The master SVGs must reproduce the approved v3 previews. Key parameters:

- **Background:** radial gradient, center `#3C3C45` → edge `#101012`, center offset to (34%, 24%).
  Full-bleed square for iOS/Watch/Widget (no baked corner — the OS masks). macOS bakes its own
  rounded-squircle + transparent margin (see §6.3).
- **Gold gradient (vertical):** `#FFF6CE` 0% → `#FCEAA0` 14% → `#E6C055` 42% → `#C4912A` 70% → `#7E5712` 100%.
- **Silver gradient (vertical):** `#FFFFFF` 0% → `#EDEFF3` 16% → `#CDD3DB` 46% → `#9AA1AB` 72% → `#63686F` 100%.
- **Gold→silver horizontal blend** (`gs`, used for B's outline/fissure): `#E9C457` → `#E7DBB9` → `#CDD3DC`.
- **Depth:** a soft drop shadow on the mark group (`dy≈2.5, blur≈2.4, black @ 50%`) and a top
  sheen overlay (`white 14% → 0`). A faint inner rim-light stroke (`white @ ~16%`) on ring marks.
- **Geometry:** authored in a 180×180 design grid (scale ×(1024/180) for export). Per-mark paths
  are captured in the v3 preview (`echo_mind_icon_family_refined_v3`) and become the master SVGs.

## 5. Production Pipeline

### 5.1 Layout

```
Tools/icon-gen/
  sources/
    circuit-brain.svg        # D — full-bleed 1024² master
    circuit-brain-small.svg  # (optional; D is bold enough without)
    hemisphere-loop.svg      # A
    topdown-brain.svg        # B
    topdown-brain-small.svg  # B — bolder folds for ≤120px
    brainwave.svg            # C
    brainwave-small.svg      # C — fatter wave/loop for ≤120px
    # (no classic-loop source: Classic Loop is preserved by copying the existing AppIcon PNG verbatim)
    _macos-frame.svg.tmpl    # rounded-squircle + margin wrapper for macOS
  generate.py                # renders sources → PNGs, writes appiconsets + Contents.json
  README.md
```

### 5.2 Generator behavior (`generate.py`)

- Renders each source SVG to required PNG sizes using **`rsvg-convert`** (installed at
  `/opt/local/bin/rsvg-convert`). Fallback: `magick`. No network, no AI.
- Knows each target's **size matrix** and **framing** (full-bleed vs macOS rounded).
- For B and C, uses the `*-small.svg` master for entries **≤120px** and the full master above that.
- Writes PNGs into the correct `.appiconset` directories and **rewrites each `Contents.json`**
  to reference them with correct `idiom`/`scale`/`size`.
- Idempotent: re-running reproduces byte-identical output (deterministic rasterizer settings).
- Invoked via a new **`make icons`** target.

### 5.3 Why this approach

Deterministic, vector-crisp, version-controlled, regenerable, and — critically — it allows a
**hand-authored bold small variant** per icon, which is the real cure for poor Home-Screen
legibility. (Contrast: today's opaque PNGs can only be regenerated by re-prompting an image model.)

## 6. Per-Target Integration

`INCLUDE_ALL_APPICON_ASSETS = YES` on iOS/macOS/Widget means **any `AppIcon-*` set auto-registers
as an alternate icon and the `CFBundleAlternateIcons` plist entries are generated automatically —
no Info.plist editing required.**

### 6.1 iOS (`EchoCore`)
- Overwrite `AppIcon.appiconset` PNG(s) with **D (Circuit Brain)** → new default.
- Before overwriting, copy the current default art into a new `AppIcon-ClassicLoop.appiconset`.
- Add `AppIcon-HemisphereLoop`, `AppIcon-TopDownBrain`, `AppIcon-Brainwave` appiconsets.
- D and A: single universal 1024 (clean downscale). B and C: **explicit iOS size matrix** so the
  `*-small.svg` art can occupy the small slots.

### 6.2 Widget (`Echo Widget`)
- Overwrite `AppIcon.appiconset` with **D**. (Single 1024 universal, matches current.)

### 6.3 macOS (`Echo macOS`)
- Overwrite `AppIcon.appiconset`'s 10 mac sizes with **D**, rendered through the **macOS framing**
  (rounded-squircle with the standard ~10% transparent margin — macOS icons are *not* full-bleed).

### 6.4 watchOS (`Echo Watch App`)
- Today the Watch **primary** is `AppIcon-ComplexWaves` (`ASSETCATALOG_COMPILER_APPICON_NAME`).
- Add an `AppIcon.appiconset` (**D**, watch sizes, full-bleed; the OS applies the circular mask)
  and set the Watch target's `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` so the watch matches
  the phone. Keep the existing Watch ComplexWaves set in place (nothing deleted).

### 6.5 Picker (`EchoCore/Views/AppIconSelectionView.swift`)
Update the `icons` array to:

```
("Circuit Brain", nil),                       // D — primary
("Hemisphere ∞", "AppIcon-HemisphereLoop"),   // A
("Top-Down Brain", "AppIcon-TopDownBrain"),   // B
("Brainwave", "AppIcon-Brainwave"),           // C
("Classic Loop", "AppIcon-ClassicLoop"),      // preserved original default
("Complex Waves", "AppIcon-ComplexWaves"),    // legacy
("Gold & Silver", "AppIcon-GoldSilver"),      // legacy
("Silver & Gold", "AppIcon-SilverGold"),      // legacy
("White Bolder", "AppIcon-WhiteBolder"),      // legacy
```

The label for the `nil` (primary) entry changes from "Default (Original)" to **"Circuit Brain"**.

## 7. Verification

- `make icons` runs clean and regenerates all PNGs deterministically.
- Each target builds with **no asset-catalog warnings** (missing sizes, wrong dimensions, alpha
  on macOS where disallowed, etc.).
- Visual check of every icon at 1024 / 180 / 120 / 80 / 60 / 40 px — B and C must stay legible
  small (the acceptance bar for the bold-variant work).
- On-device/simulator: open the icon picker, switch to each alternate, confirm the Home-Screen
  icon changes and `currentIcon` check-marks track correctly (iOS).
- macOS: confirm the Dock/Finder icon shows D with correct rounded framing and margin.

## 8. Risks & Mitigations

- **macOS rounded framing fidelity** — the trickiest piece. Mitigate with a dedicated
  `_macos-frame.svg.tmpl` wrapper and side-by-side comparison against an Apple HIG macOS icon
  template before committing.
- **`rsvg-convert` gradient/shadow fidelity** — verify the metal gradients and drop shadow render
  faithfully; if `rsvg-convert` differs from the browser preview, fall back to `magick` or inline
  the shadow as a baked gradient rather than an SVG filter.
- **Alternate-icon size requirements** — multi-size appiconsets (B/C) must declare every slot the
  build expects; a missing 120/180 entry fails alternate-icon switching at runtime. The generator
  owns the full matrix to prevent this.
- **Watch primary repoint** — changing `ASSETCATALOG_COMPILER_APPICON_NAME` is a project-file edit;
  verify the Watch target still builds and the App Store/TestFlight pipeline accepts the new icon.
- **Schema/migration:** none. This is asset + view + project-config only; no database changes.

## 9. Documentation impact

- Update `README.md` / any "alternate icons" note to describe the new family.
- Add `Tools/icon-gen/README.md` documenting `make icons` and how to tweak a master SVG.
- `ARCHITECTURE.md`: no structural change, but note the icon pipeline under tooling if a tooling
  section exists.
