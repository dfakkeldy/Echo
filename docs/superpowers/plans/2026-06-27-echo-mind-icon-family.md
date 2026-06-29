# Echo "Mind" Icon Family Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a cohesive gold/silver-on-dark "Mind" app-icon family — a new Circuit Brain default plus Hemisphere ∞, Top-Down Brain, and Brainwave alternates — produced by a version-controlled SVG→PNG pipeline, across iOS/Watch/Widget/macOS.

**Architecture:** Master art lives as SVGs in `Tools/icon-gen/sources/`. A stdlib-Python generator (`Tools/icon-gen/generate.py`) rasterizes them with `rsvg-convert` into each target's `.appiconset` and rewrites `Contents.json`. A `make icons` target wraps it. The new default (D) replaces the primary `AppIcon` on every target; A/B/C/Classic Loop are added as iOS alternates (auto-registered via `INCLUDE_ALL_APPICON_ASSETS = YES`); the picker array in `AppIconSelectionView.swift` is extended by hand.

**Tech Stack:** SVG (viewBox design grid), `rsvg-convert` 2.56.3, ImageMagick (PNG post-processing only), Python 3 (stdlib), Make, Xcode asset catalogs, SwiftUI.

## Global Constraints

- **Rasterizer:** SVG→PNG uses `/opt/local/bin/rsvg-convert` (v2.56.3) ONLY. ImageMagick on this machine has NO librsvg delegate and renders SVGs as flat-black silhouettes — it must NEVER rasterize an SVG. Use `magick`/`sips` only to post-process existing PNGs (flatten/strip-alpha/identify).
- **SVG authoring:** every source uses `viewBox="0 0 180 180"` (the 180-unit design grid; rsvg scales to any pixel size via `-w/-h`). Do NOT use the CSS `transform-origin` attribute — rsvg ignores it. Bake any pivot as `transform="translate(cx,cy) scale(s) translate(-cx,-cy)"`. `feDropShadow` is supported on 2.56.3 and may be used.
- **iOS / Watch / Widget icons:** full-bleed square art, NO alpha (flatten after render), NO baked rounded corners (the OS applies the mask). iOS app icons with an alpha channel are rejected by actool/App Store.
- **macOS icons:** RGBA with a baked rounded-squircle + ~10% transparent margin + soft shadow (the system does NOT mask macOS icons). Full 10-entry matrix; 7 physical files (16/32/64/128/256/512/1024 px).
- **Only the default (D)** gets macOS, Watch, and Widget art. Alternates (A/B/C/Classic) are **iOS-only** — macOS has no `setAlternateIconName` and the Watch cannot switch icons at runtime.
- **iOS size rules:** single 1024 universal works for the primary and for single-art alternates (A, Classic). Alternates that need DIFFERENT bold art at small sizes (B, C) use the explicit iPhone matrix: 20/29/40/60 pt @2x/3x + a 1024 ios-marketing slot. Use the bold `*-small.svg` art at/below **120 px**; the full master at 180 px and 1024 px.
- **Alternate registration:** `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES` (iOS target) auto-exposes any `AppIcon-*` set as a `CFBundleAlternateIcons` entry — NO Info.plist editing. The name passed to `setAlternateIconName` must exactly match the `.appiconset` name. The picker list in `AppIconSelectionView.swift` is hand-maintained — a new icon needs BOTH the appiconset AND a tuple in the array.
- **Watch repoint:** set the Watch target's `ASSETCATALOG_COMPILER_APPICON_NAME` from `AppIcon-ComplexWaves` to `AppIcon` (Debug + Release) and add a Watch `AppIcon.appiconset` (D). Keep the ComplexWaves watch set in place.
- **Preserve everything:** copy today's iOS `AppIcon.png` into a new `AppIcon-ClassicLoop.appiconset` BEFORE regenerating the primary, so the current default is never lost. Keep the four legacy alternates untouched.
- **Branch/commit:** this worktree is based on `nightly`. Commit per task (Conventional Commits). Do NOT push or open a PR unless explicitly asked.
- **Build gating (16 GB Mac):** never run two `xcodebuild`s at once or enable parallel testing. Prefix any build with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&`. Verification builds pass `CODE_SIGNING_ALLOWED=NO`.

## File Structure

```
Tools/icon-gen/
  generate.py                    # CREATE — the generator (stdlib only)
  README.md                      # CREATE — how to run / tweak
  sources/
    circuit-brain.svg            # CREATE — D, full-bleed (iOS/Widget/Watch)
    circuit-brain-macos.svg      # CREATE — D, macOS squircle+margin (RGBA)
    hemisphere-loop.svg          # CREATE — A, full-bleed
    topdown-brain.svg            # CREATE — B, full-bleed
    topdown-brain-small.svg      # CREATE — B, bold small variant (<=120px)
    brainwave.svg                # CREATE — C, full-bleed
    brainwave-small.svg          # CREATE — C, bold small variant (<=120px)
Makefile                         # MODIFY — add `icons` target
EchoCore/Assets.xcassets/
  AppIcon.appiconset/            # MODIFY — becomes D
  AppIcon-ClassicLoop.appiconset/      # CREATE — preserved original default
  AppIcon-HemisphereLoop.appiconset/   # CREATE — A
  AppIcon-TopDownBrain.appiconset/     # CREATE — B
  AppIcon-Brainwave.appiconset/        # CREATE — C
Echo macOS/Assets.xcassets/AppIcon.appiconset/   # MODIFY — becomes D (HIG framed)
Echo Widget/Assets.xcassets/AppIcon.appiconset/  # MODIFY — becomes D
Echo Watch App/Assets.xcassets/AppIcon.appiconset/  # CREATE — D (watch)
EchoCore/Views/AppIconSelectionView.swift        # MODIFY — picker array
Echo.xcodeproj/project.pbxproj                    # MODIFY — Watch APPICON_NAME
README.md / ARCHITECTURE.md                        # MODIFY — doc sync
```

---

### Task 1: Preserve the current default as "Classic Loop"

This must happen FIRST — Task 5 overwrites the iOS `AppIcon.png`, so the original art has to be copied out before then. Pure file operation; no generator yet.

**Files:**
- Create: `EchoCore/Assets.xcassets/AppIcon-ClassicLoop.appiconset/icon.png` (copy)
- Create: `EchoCore/Assets.xcassets/AppIcon-ClassicLoop.appiconset/Contents.json`

- [ ] **Step 1: Copy the current primary icon into the new set**

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p EchoCore/Assets.xcassets/AppIcon-ClassicLoop.appiconset
cp EchoCore/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
   EchoCore/Assets.xcassets/AppIcon-ClassicLoop.appiconset/icon.png
```

- [ ] **Step 2: Write its Contents.json**

Create `EchoCore/Assets.xcassets/AppIcon-ClassicLoop.appiconset/Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "icon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Verify the copy is a real 1024 icon**

Run: `sips -g pixelWidth -g pixelHeight EchoCore/Assets.xcassets/AppIcon-ClassicLoop.appiconset/icon.png`
Expected: `pixelWidth: 1024` and `pixelHeight: 1024`.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Assets.xcassets/AppIcon-ClassicLoop.appiconset
git commit -m "feat(icons): preserve current default app icon as Classic Loop alternate"
```

---

### Task 2: Scaffold the generator + D full-bleed master, render iOS primary

Builds the pipeline engine and proves it end-to-end by replacing the iOS default with D.

**Files:**
- Create: `Tools/icon-gen/sources/circuit-brain.svg`
- Create: `Tools/icon-gen/generate.py`
- Modify: `EchoCore/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (regenerated)
- Modify: `EchoCore/Assets.xcassets/AppIcon.appiconset/Contents.json` (rewritten)

**Interfaces:**
- Produces: `generate.py` exposes `TARGETS = {"default","hemisphere","topdown","brainwave"}` runnable via `python3 Tools/icon-gen/generate.py [--only NAME ...]`; helpers `render(svg, px, out, *, keep_alpha, bg)`, `gen_ios_universal`, `gen_ios_matrix`, `gen_macos`, `gen_watch`, `write_contents`. Later tasks add source SVGs and run `--only`.

- [ ] **Step 1: Author the D (Circuit Brain) full-bleed master**

Create `Tools/icon-gen/sources/circuit-brain.svg`:

```svg
<svg width="1024" height="1024" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
<defs>
<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFF6CE"/><stop offset="0.14" stop-color="#FCEAA0"/><stop offset="0.42" stop-color="#E6C055"/><stop offset="0.7" stop-color="#C4912A"/><stop offset="1" stop-color="#7E5712"/>
</linearGradient>
<linearGradient id="silver" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.16" stop-color="#EDEFF3"/><stop offset="0.46" stop-color="#CDD3DB"/><stop offset="0.72" stop-color="#9AA1AB"/><stop offset="1" stop-color="#63686F"/>
</linearGradient>
<radialGradient id="bgg" cx="0.34" cy="0.24" r="0.98">
<stop offset="0" stop-color="#3C3C45"/><stop offset="1" stop-color="#101012"/>
</radialGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<filter id="ds" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="2.5" stdDeviation="2.4" flood-color="#000000" flood-opacity="0.5"/></filter>
</defs>
<rect width="180" height="180" fill="url(#bgg)"/>
<rect width="180" height="180" fill="url(#sheen)"/>
<g filter="url(#ds)">
<path d="M54,124 C28,114 26,72 52,54 C66,42 88,38 102,48 C130,36 158,58 150,86 C147,108 130,117 120,121 C112,127 104,129 98,127 C91,133 80,132 74,127 C68,130 60,130 54,124 Z" fill="#D6DDE8" fill-opacity="0.06" stroke="url(#silver)" stroke-width="6.5"/>
<path d="M68,88 a12,10 0 1 1 24,0 a12,10 0 1 0 24,0" fill="none" stroke="url(#gold)" stroke-width="6" stroke-linecap="round"/>
<path d="M46,68 q15,-11 29,4" fill="none" stroke="url(#gold)" stroke-width="5.4" stroke-linecap="round"/>
<path d="M48,106 q17,13 33,1" fill="none" stroke="url(#silver)" stroke-width="5.4" stroke-linecap="round"/>
<path d="M128,88 l14,0" fill="none" stroke="url(#gold)" stroke-width="3" stroke-linecap="round"/>
<circle cx="46" cy="68" r="4.2" fill="url(#gold)"/><circle cx="48" cy="106" r="4.2" fill="url(#silver)"/><circle cx="146" cy="88" r="4.2" fill="url(#gold)"/>
</g>
</svg>
```

- [ ] **Step 2: Write the generator**

Create `Tools/icon-gen/generate.py`:

```python
#!/usr/bin/env python3
"""Echo app-icon generator.

Renders master SVGs (Tools/icon-gen/sources/*.svg) into the asset catalogs
for every target. SVG rasterization uses rsvg-convert ONLY — it is the only
faithful SVG renderer on this machine (ImageMagick has no librsvg delegate
and renders SVGs as flat black). magick is used solely to flatten alpha on
already-rendered PNGs (iOS/Watch app icons must be opaque RGB).

Usage: python3 Tools/icon-gen/generate.py [--only default hemisphere topdown brainwave]
"""
import argparse
import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent / "sources"
RSVG = "/opt/local/bin/rsvg-convert"
MAGICK = "magick"

IOS_ASSETS = REPO / "EchoCore/Assets.xcassets"
MAC_ASSETS = REPO / "Echo macOS/Assets.xcassets"
WIDGET_ASSETS = REPO / "Echo Widget/Assets.xcassets"
WATCH_ASSETS = REPO / "Echo Watch App/Assets.xcassets"

DARK_BG = "#101012"


def render(svg: Path, px: int, out: Path, *, keep_alpha: bool, bg: str = DARK_BG) -> None:
    """Rasterize one SVG to a square PNG. Flatten alpha unless keep_alpha."""
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([RSVG, "-w", str(px), "-h", str(px), str(svg), "-o", str(out)], check=True)
    if not keep_alpha:
        # iOS/Watch icons must be opaque RGB — strip the (fully opaque) alpha channel.
        subprocess.run(
            [MAGICK, str(out), "-background", bg, "-alpha", "remove", "-alpha", "off", str(out)],
            check=True,
        )


def write_contents(dirpath: Path, images: list, properties: dict | None = None) -> None:
    doc = {"images": images, "info": {"author": "xcode", "version": 1}}
    if properties:
        doc["properties"] = properties
    (dirpath / "Contents.json").write_text(json.dumps(doc, indent=2) + "\n")


def gen_ios_universal(svg: Path, dest_set: Path, filename: str = "icon.png", platform: str = "ios") -> None:
    """Single 1024 universal full-bleed icon (primary or single-art alternate)."""
    render(svg, 1024, dest_set / filename, keep_alpha=False)
    write_contents(dest_set, [
        {"filename": filename, "idiom": "universal", "platform": platform, "size": "1024x1024"},
    ])


# iPhone explicit matrix: bold *-small art at/below 120px, full art above.
IPHONE_MATRIX = [
    ("20x20", "2x", 40), ("20x20", "3x", 60),
    ("29x29", "2x", 58), ("29x29", "3x", 87),
    ("40x40", "2x", 80), ("40x40", "3x", 120),
    ("60x60", "2x", 120), ("60x60", "3x", 180),
]
SMALL_BREAKPOINT_PX = 120


def gen_ios_matrix(svg_full: Path, svg_small: Path, dest_set: Path) -> None:
    """Explicit iPhone matrix so small slots can carry the bold variant art."""
    images = []
    rendered = set()
    for size, scale, px in IPHONE_MATRIX:
        src = svg_small if px <= SMALL_BREAKPOINT_PX else svg_full
        fn = f"icon-{px}.png"
        if fn not in rendered:
            render(src, px, dest_set / fn, keep_alpha=False)
            rendered.add(fn)
        images.append({"filename": fn, "idiom": "iphone", "scale": scale, "size": size})
    render(svg_full, 1024, dest_set / "icon-1024.png", keep_alpha=False)
    images.append({"filename": "icon-1024.png", "idiom": "ios-marketing", "scale": "1x", "size": "1024x1024"})
    write_contents(dest_set, images)


MAC_PHYS = [16, 32, 64, 128, 256, 512, 1024]
MAC_ENTRIES = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]


def gen_macos(svg_mac: Path, dest_set: Path) -> None:
    """10-entry macOS matrix; RGBA so the squircle margin stays transparent."""
    for px in MAC_PHYS:
        render(svg_mac, px, dest_set / f"AppIcon-mac-{px}.png", keep_alpha=True)
    images = [
        {"filename": f"AppIcon-mac-{px}.png", "idiom": "mac", "scale": scale, "size": size}
        for size, scale, px in MAC_ENTRIES
    ]
    write_contents(dest_set, images)


def gen_watch(svg: Path, dest_set: Path, filename: str = "icon.png") -> None:
    """Single 1024 watch icon (watch + watch-marketing idioms, pre-rendered)."""
    render(svg, 1024, dest_set / filename, keep_alpha=False)
    write_contents(dest_set, [
        {"filename": filename, "idiom": "watch", "scale": "1x", "size": "1024x1024"},
        {"filename": filename, "idiom": "watch-marketing", "scale": "1x", "size": "1024x1024"},
    ], properties={"pre-rendered": True})


def gen_default() -> None:      # D — every target
    gen_ios_universal(SRC / "circuit-brain.svg", IOS_ASSETS / "AppIcon.appiconset", filename="AppIcon.png")
    gen_ios_universal(SRC / "circuit-brain.svg", WIDGET_ASSETS / "AppIcon.appiconset", filename="AppIcon.png")
    gen_macos(SRC / "circuit-brain-macos.svg", MAC_ASSETS / "AppIcon.appiconset")
    gen_watch(SRC / "circuit-brain.svg", WATCH_ASSETS / "AppIcon.appiconset")


def gen_hemisphere() -> None:   # A — iOS alternate
    gen_ios_universal(SRC / "hemisphere-loop.svg", IOS_ASSETS / "AppIcon-HemisphereLoop.appiconset")


def gen_topdown() -> None:      # B — iOS alternate, bold small
    gen_ios_matrix(SRC / "topdown-brain.svg", SRC / "topdown-brain-small.svg",
                   IOS_ASSETS / "AppIcon-TopDownBrain.appiconset")


def gen_brainwave() -> None:    # C — iOS alternate, bold small
    gen_ios_matrix(SRC / "brainwave.svg", SRC / "brainwave-small.svg",
                   IOS_ASSETS / "AppIcon-Brainwave.appiconset")


TARGETS = {
    "default": gen_default,
    "hemisphere": gen_hemisphere,
    "topdown": gen_topdown,
    "brainwave": gen_brainwave,
}


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate Echo app icons from SVG masters.")
    ap.add_argument("--only", nargs="*", choices=list(TARGETS), help="generate only these targets")
    args = ap.parse_args()
    for name in (args.only or list(TARGETS)):
        print(f"[icon-gen] generating: {name}")
        TARGETS[name]()
    print("[icon-gen] done — review `git diff` in *.xcassets before committing.")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run the generator for the iOS + Widget default**

Run: `python3 Tools/icon-gen/generate.py --only default`
Expected: prints `[icon-gen] generating: default` then `done`. (It also writes macOS/Watch sets, whose source SVGs are created in Tasks 3–4; if those SVGs are missing this run fails at the macOS step. To render only iOS+Widget for this task, temporarily comment the `gen_macos`/`gen_watch` lines in `gen_default`, OR run the inline render below.)

Run (scoped to iOS + Widget only, no source dependency on later tasks):
```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "Tools/icon-gen")
import generate as g
g.gen_ios_universal(g.SRC/"circuit-brain.svg", g.IOS_ASSETS/"AppIcon.appiconset", filename="AppIcon.png")
g.gen_ios_universal(g.SRC/"circuit-brain.svg", g.WIDGET_ASSETS/"AppIcon.appiconset", filename="AppIcon.png")
print("iOS + Widget primary regenerated")
PY
```

- [ ] **Step 4: Verify the new iOS default is 1024², opaque, and not black**

Run:
```bash
sips -g pixelWidth -g pixelHeight -g hasAlpha EchoCore/Assets.xcassets/AppIcon.appiconset/AppIcon.png
magick EchoCore/Assets.xcassets/AppIcon.appiconset/AppIcon.png -format 'center=%[pixel:p{512,300}] corner=%[pixel:p{30,30}]\n' info:
```
Expected: `pixelWidth: 1024`, `pixelHeight: 1024`, `hasAlpha: no`. The `center` pixel is a light silver/grey (the brain stroke, NOT `srgb(0,0,0)` and NOT black), and the `corner` pixel is a dark charcoal near `srgb(40,40,46)` — proving gradients rendered (not a flat-black magick failure).

- [ ] **Step 5: Visually confirm the rendered icon**

Render a preview into the scratchpad and open it to confirm it matches the approved Circuit Brain:
```bash
/opt/local/bin/rsvg-convert -w 256 -h 256 Tools/icon-gen/sources/circuit-brain.svg -o /tmp/echo-d-preview.png
```
Read `/tmp/echo-d-preview.png` and confirm: dark tile, silver brain outline, gold ∞-folds, three node dots. If wrong, fix the SVG and re-run Steps 3–4.

- [ ] **Step 6: Commit**

```bash
git add Tools/icon-gen/generate.py Tools/icon-gen/sources/circuit-brain.svg \
        EchoCore/Assets.xcassets/AppIcon.appiconset "Echo Widget/Assets.xcassets/AppIcon.appiconset"
git commit -m "feat(icons): add SVG icon pipeline; set Circuit Brain as iOS/Widget default"
```

---

### Task 3: macOS default (D) with HIG squircle framing

**Files:**
- Create: `Tools/icon-gen/sources/circuit-brain-macos.svg`
- Modify: `Echo macOS/Assets.xcassets/AppIcon.appiconset/` (7 PNGs + Contents.json regenerated)

**Interfaces:**
- Consumes: `gen_macos(svg_mac, dest_set)` from Task 2.

- [ ] **Step 1: Author the macOS-framed D master (RGBA, rounded body + margin + shadow)**

Create `Tools/icon-gen/sources/circuit-brain-macos.svg`:

```svg
<svg width="1024" height="1024" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
<defs>
<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFF6CE"/><stop offset="0.14" stop-color="#FCEAA0"/><stop offset="0.42" stop-color="#E6C055"/><stop offset="0.7" stop-color="#C4912A"/><stop offset="1" stop-color="#7E5712"/>
</linearGradient>
<linearGradient id="silver" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.16" stop-color="#EDEFF3"/><stop offset="0.46" stop-color="#CDD3DB"/><stop offset="0.72" stop-color="#9AA1AB"/><stop offset="1" stop-color="#63686F"/>
</linearGradient>
<radialGradient id="bgg" cx="0.34" cy="0.24" r="0.98">
<stop offset="0" stop-color="#3C3C45"/><stop offset="1" stop-color="#101012"/>
</radialGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<filter id="ds" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="2" stdDeviation="2" flood-color="#000000" flood-opacity="0.5"/></filter>
<filter id="macshadow" x="-25%" y="-25%" width="150%" height="160%"><feDropShadow dx="0" dy="4" stdDeviation="5" flood-color="#000000" flood-opacity="0.4"/></filter>
</defs>
<g filter="url(#macshadow)">
<rect x="17" y="15" width="146" height="146" rx="33" fill="url(#bgg)"/>
</g>
<rect x="17" y="15" width="146" height="146" rx="33" fill="url(#sheen)"/>
<g transform="translate(90,88) scale(0.8) translate(-90,-88)">
<g filter="url(#ds)">
<path d="M54,124 C28,114 26,72 52,54 C66,42 88,38 102,48 C130,36 158,58 150,86 C147,108 130,117 120,121 C112,127 104,129 98,127 C91,133 80,132 74,127 C68,130 60,130 54,124 Z" fill="#D6DDE8" fill-opacity="0.06" stroke="url(#silver)" stroke-width="6.5"/>
<path d="M68,88 a12,10 0 1 1 24,0 a12,10 0 1 0 24,0" fill="none" stroke="url(#gold)" stroke-width="6" stroke-linecap="round"/>
<path d="M46,68 q15,-11 29,4" fill="none" stroke="url(#gold)" stroke-width="5.4" stroke-linecap="round"/>
<path d="M48,106 q17,13 33,1" fill="none" stroke="url(#silver)" stroke-width="5.4" stroke-linecap="round"/>
<path d="M128,88 l14,0" fill="none" stroke="url(#gold)" stroke-width="3" stroke-linecap="round"/>
<circle cx="46" cy="68" r="4.2" fill="url(#gold)"/><circle cx="48" cy="106" r="4.2" fill="url(#silver)"/><circle cx="146" cy="88" r="4.2" fill="url(#gold)"/>
</g>
</g>
</svg>
```

- [ ] **Step 2: Generate the macOS set**

Run:
```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "Tools/icon-gen")
import generate as g
g.gen_macos(g.SRC/"circuit-brain-macos.svg", g.MAC_ASSETS/"AppIcon.appiconset")
print("macOS AppIcon regenerated")
PY
```

- [ ] **Step 3: Verify macOS PNGs are RGBA with a transparent margin**

Run:
```bash
sips -g pixelWidth -g hasAlpha "Echo macOS/Assets.xcassets/AppIcon.appiconset/AppIcon-mac-1024.png"
magick "Echo macOS/Assets.xcassets/AppIcon.appiconset/AppIcon-mac-1024.png" -format 'corner_alpha=%[pixel:p{10,10}]\n' info:
```
Expected: `pixelWidth: 1024`, `hasAlpha: yes`, and `corner_alpha` is fully transparent `srgba(0,0,0,0)` (the margin) — proving the squircle framing, not full-bleed.

- [ ] **Step 4: Visually confirm**

```bash
/opt/local/bin/rsvg-convert -w 256 -h 256 Tools/icon-gen/sources/circuit-brain-macos.svg -o /tmp/echo-d-mac.png
```
Read `/tmp/echo-d-mac.png`: a rounded-rect dark tile with a margin and soft shadow, brain centered inside. Adjust `rx`/margin/scale if it looks cramped or the corners look wrong versus a standard macOS icon.

- [ ] **Step 5: Commit**

```bash
git add Tools/icon-gen/sources/circuit-brain-macos.svg "Echo macOS/Assets.xcassets/AppIcon.appiconset"
git commit -m "feat(icons): set Circuit Brain as macOS default with HIG squircle framing"
```

---

### Task 4: Watch default (D) + repoint Watch target

**Files:**
- Create: `Echo Watch App/Assets.xcassets/AppIcon.appiconset/` (icon.png + Contents.json)
- Modify: `Echo.xcodeproj/project.pbxproj` (Watch `ASSETCATALOG_COMPILER_APPICON_NAME`)

- [ ] **Step 1: Generate the Watch icon set**

```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "Tools/icon-gen")
import generate as g
g.gen_watch(g.SRC/"circuit-brain.svg", g.WATCH_ASSETS/"AppIcon.appiconset")
print("Watch AppIcon created")
PY
```

- [ ] **Step 2: Verify the Watch set**

Run: `sips -g pixelWidth -g hasAlpha "Echo Watch App/Assets.xcassets/AppIcon.appiconset/icon.png" && cat "Echo Watch App/Assets.xcassets/AppIcon.appiconset/Contents.json"`
Expected: `pixelWidth: 1024`, `hasAlpha: no`; Contents.json lists `watch` + `watch-marketing` entries and `"properties": {"pre-rendered": true}`.

- [ ] **Step 3: Repoint the Watch target's primary icon (both configs)**

In `Echo.xcodeproj/project.pbxproj`, change BOTH Watch-target occurrences (Debug + Release) from:
```
ASSETCATALOG_COMPILER_APPICON_NAME = "AppIcon-ComplexWaves";
```
to:
```
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
```

Verify exactly two changed and none remain referencing ComplexWaves as the icon name:
```bash
grep -n 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' Echo.xcodeproj/project.pbxproj | wc -l   # expect >= 6 (app, widget, macos, +watch x2)
grep -n 'AppIcon-ComplexWaves";' Echo.xcodeproj/project.pbxproj | grep APPICON_NAME               # expect: no output
```
Expected: no `APPICON_NAME` line still set to `AppIcon-ComplexWaves`.

- [ ] **Step 4: Commit**

```bash
git add "Echo Watch App/Assets.xcassets/AppIcon.appiconset" Echo.xcodeproj/project.pbxproj
git commit -m "feat(icons): give the Watch the Circuit Brain default icon"
```

---

### Task 5: Hemisphere ∞ (A) iOS alternate

**Files:**
- Create: `Tools/icon-gen/sources/hemisphere-loop.svg`
- Create: `EchoCore/Assets.xcassets/AppIcon-HemisphereLoop.appiconset/`

- [ ] **Step 1: Author the A master**

Create `Tools/icon-gen/sources/hemisphere-loop.svg`:

```svg
<svg width="1024" height="1024" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
<defs>
<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFF6CE"/><stop offset="0.14" stop-color="#FCEAA0"/><stop offset="0.42" stop-color="#E6C055"/><stop offset="0.7" stop-color="#C4912A"/><stop offset="1" stop-color="#7E5712"/>
</linearGradient>
<linearGradient id="silver" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.16" stop-color="#EDEFF3"/><stop offset="0.46" stop-color="#CDD3DB"/><stop offset="0.72" stop-color="#9AA1AB"/><stop offset="1" stop-color="#63686F"/>
</linearGradient>
<radialGradient id="bgg" cx="0.34" cy="0.24" r="0.98">
<stop offset="0" stop-color="#3C3C45"/><stop offset="1" stop-color="#101012"/>
</radialGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<filter id="ds" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="2.5" stdDeviation="2.4" flood-color="#000000" flood-opacity="0.5"/></filter>
</defs>
<rect width="180" height="180" fill="url(#bgg)"/>
<rect width="180" height="180" fill="url(#sheen)"/>
<g filter="url(#ds)">
<circle cx="62" cy="90" r="32" fill="none" stroke="url(#gold)" stroke-width="13"/>
<circle cx="118" cy="90" r="32" fill="none" stroke="url(#silver)" stroke-width="13"/>
<circle cx="62" cy="90" r="26.5" fill="none" stroke="#FFFFFF" stroke-width="1.6" stroke-opacity="0.16"/>
<circle cx="118" cy="90" r="26.5" fill="none" stroke="#FFFFFF" stroke-width="1.6" stroke-opacity="0.16"/>
<path d="M110,76 L110,104 L134,90 Z" fill="url(#gold)"/>
<path d="M110,76 L134,90" stroke="#FFF6CE" stroke-width="1.4" stroke-opacity="0.7"/>
<circle cx="62" cy="58" r="3.2" fill="url(#gold)"/><circle cx="62" cy="122" r="3.2" fill="url(#gold)"/><circle cx="118" cy="58" r="3.2" fill="url(#silver)"/><circle cx="118" cy="122" r="3.2" fill="url(#silver)"/>
</g>
</svg>
```

- [ ] **Step 2: Generate the alternate**

Run: `python3 Tools/icon-gen/generate.py --only hemisphere`
Expected: prints `generating: hemisphere` then `done`.

- [ ] **Step 3: Verify**

Run: `sips -g pixelWidth -g hasAlpha EchoCore/Assets.xcassets/AppIcon-HemisphereLoop.appiconset/icon.png`
Expected: `pixelWidth: 1024`, `hasAlpha: no`. Render a 256 preview to `/tmp` and Read it: two metal rings (gold left, silver right) forming an ∞ with a gold play triangle in the right loop.

- [ ] **Step 4: Commit**

```bash
git add Tools/icon-gen/sources/hemisphere-loop.svg EchoCore/Assets.xcassets/AppIcon-HemisphereLoop.appiconset
git commit -m "feat(icons): add Hemisphere infinity alternate icon"
```

---

### Task 6: Top-Down Brain (B) iOS alternate with bold small variant

**Files:**
- Create: `Tools/icon-gen/sources/topdown-brain.svg`
- Create: `Tools/icon-gen/sources/topdown-brain-small.svg`
- Create: `EchoCore/Assets.xcassets/AppIcon-TopDownBrain.appiconset/`

- [ ] **Step 1: Author the B full master**

Create `Tools/icon-gen/sources/topdown-brain.svg`:

```svg
<svg width="1024" height="1024" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
<defs>
<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFF6CE"/><stop offset="0.14" stop-color="#FCEAA0"/><stop offset="0.42" stop-color="#E6C055"/><stop offset="0.7" stop-color="#C4912A"/><stop offset="1" stop-color="#7E5712"/>
</linearGradient>
<linearGradient id="silver" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.16" stop-color="#EDEFF3"/><stop offset="0.46" stop-color="#CDD3DB"/><stop offset="0.72" stop-color="#9AA1AB"/><stop offset="1" stop-color="#63686F"/>
</linearGradient>
<linearGradient id="gs" x1="0" y1="0" x2="1" y2="0">
<stop offset="0" stop-color="#E9C457"/><stop offset="0.5" stop-color="#E7DBB9"/><stop offset="1" stop-color="#CDD3DC"/>
</linearGradient>
<radialGradient id="bgg" cx="0.34" cy="0.24" r="0.98">
<stop offset="0" stop-color="#3C3C45"/><stop offset="1" stop-color="#101012"/>
</radialGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<filter id="ds" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="2.5" stdDeviation="2.4" flood-color="#000000" flood-opacity="0.5"/></filter>
</defs>
<rect width="180" height="180" fill="url(#bgg)"/>
<rect width="180" height="180" fill="url(#sheen)"/>
<g filter="url(#ds)">
<path d="M90,44 C66,44 48,55 42,74 C36,94 43,114 62,128 C73,136 81,134 90,131 C99,134 107,136 118,128 C137,114 144,94 138,74 C132,55 114,44 90,44 Z" fill="#D6DDE8" fill-opacity="0.06" stroke="url(#gs)" stroke-width="6"/>
<path d="M90,52 C76,65 104,79 90,92 C76,105 104,119 90,130" fill="none" stroke="url(#gs)" stroke-width="3.2" stroke-linecap="round"/>
<path d="M78,92 a7,6 0 1 1 12,0 a7,6 0 1 0 12,0" fill="none" stroke="url(#gold)" stroke-width="3.6" stroke-linecap="round"/>
<path d="M58,64 q11,9 3,20 q-6,11 6,19" fill="none" stroke="url(#gold)" stroke-width="3" stroke-linecap="round"/>
<path d="M122,64 q-11,9 -3,20 q6,11 -6,19" fill="none" stroke="url(#silver)" stroke-width="3" stroke-linecap="round"/>
<path d="M50,86 q9,5 5,15" fill="none" stroke="url(#gold)" stroke-width="2.6" stroke-linecap="round" opacity="0.85"/>
<path d="M130,86 q-9,5 -5,15" fill="none" stroke="url(#silver)" stroke-width="2.6" stroke-linecap="round" opacity="0.85"/>
<circle cx="58" cy="64" r="3" fill="url(#gold)"/><circle cx="122" cy="64" r="3" fill="url(#silver)"/><circle cx="67" cy="105" r="3" fill="url(#gold)"/><circle cx="113" cy="105" r="3" fill="url(#silver)"/>
</g>
</svg>
```

- [ ] **Step 2: Author the B bold small variant**

Create `Tools/icon-gen/sources/topdown-brain-small.svg` (same defs; thicker strokes, fewer details):

```svg
<svg width="1024" height="1024" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
<defs>
<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFF6CE"/><stop offset="0.14" stop-color="#FCEAA0"/><stop offset="0.42" stop-color="#E6C055"/><stop offset="0.7" stop-color="#C4912A"/><stop offset="1" stop-color="#7E5712"/>
</linearGradient>
<linearGradient id="silver" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.16" stop-color="#EDEFF3"/><stop offset="0.46" stop-color="#CDD3DB"/><stop offset="0.72" stop-color="#9AA1AB"/><stop offset="1" stop-color="#63686F"/>
</linearGradient>
<linearGradient id="gs" x1="0" y1="0" x2="1" y2="0">
<stop offset="0" stop-color="#E9C457"/><stop offset="0.5" stop-color="#E7DBB9"/><stop offset="1" stop-color="#CDD3DC"/>
</linearGradient>
<radialGradient id="bgg" cx="0.34" cy="0.24" r="0.98">
<stop offset="0" stop-color="#3C3C45"/><stop offset="1" stop-color="#101012"/>
</radialGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
</defs>
<rect width="180" height="180" fill="url(#bgg)"/>
<rect width="180" height="180" fill="url(#sheen)"/>
<path d="M90,42 C64,42 45,54 39,74 C33,95 41,116 62,131 C74,139 82,137 90,134 C98,137 106,139 118,131 C139,116 147,95 141,74 C135,54 116,42 90,42 Z" fill="#D6DDE8" fill-opacity="0.06" stroke="url(#gs)" stroke-width="8"/>
<path d="M90,50 C75,64 105,78 90,92 C75,106 105,120 90,132" fill="none" stroke="url(#gs)" stroke-width="5" stroke-linecap="round"/>
<path d="M77,92 a8,7 0 1 1 13,0 a8,7 0 1 0 13,0" fill="none" stroke="url(#gold)" stroke-width="5.5" stroke-linecap="round"/>
<path d="M56,62 q12,10 3,22 q-6,12 7,20" fill="none" stroke="url(#gold)" stroke-width="5" stroke-linecap="round"/>
<path d="M124,62 q-12,10 -3,22 q6,12 -7,20" fill="none" stroke="url(#silver)" stroke-width="5" stroke-linecap="round"/>
<circle cx="56" cy="62" r="4.5" fill="url(#gold)"/><circle cx="124" cy="62" r="4.5" fill="url(#silver)"/>
</svg>
```

- [ ] **Step 3: Generate the alternate (multi-size)**

Run: `python3 Tools/icon-gen/generate.py --only topdown`
Expected: prints `generating: topdown` then `done`.

- [ ] **Step 4: Verify the matrix and the small/large split**

Run:
```bash
cat EchoCore/Assets.xcassets/AppIcon-TopDownBrain.appiconset/Contents.json
for f in icon-40 icon-120 icon-180 icon-1024; do sips -g pixelWidth -g hasAlpha "EchoCore/Assets.xcassets/AppIcon-TopDownBrain.appiconset/$f.png"; done
```
Expected: Contents.json has 9 image entries (8 iphone + 1 ios-marketing); `icon-40` is 40px, `icon-120` 120px, `icon-180` 180px, `icon-1024` 1024px, all `hasAlpha: no`. Read `/tmp` 40px previews of both masters — the small one must read clearly (bold folds) where the full one would blur.

- [ ] **Step 5: Commit**

```bash
git add Tools/icon-gen/sources/topdown-brain.svg Tools/icon-gen/sources/topdown-brain-small.svg EchoCore/Assets.xcassets/AppIcon-TopDownBrain.appiconset
git commit -m "feat(icons): add Top-Down Brain alternate with bold small variant"
```

---

### Task 7: Brainwave (C) iOS alternate with bold small variant

**Files:**
- Create: `Tools/icon-gen/sources/brainwave.svg`
- Create: `Tools/icon-gen/sources/brainwave-small.svg`
- Create: `EchoCore/Assets.xcassets/AppIcon-Brainwave.appiconset/`

Note: the preview's inner rim-light used `transform-origin` (which rsvg ignores) — it is omitted here per the Global Constraints.

- [ ] **Step 1: Author the C full master**

Create `Tools/icon-gen/sources/brainwave.svg`:

```svg
<svg width="1024" height="1024" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
<defs>
<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFF6CE"/><stop offset="0.14" stop-color="#FCEAA0"/><stop offset="0.42" stop-color="#E6C055"/><stop offset="0.7" stop-color="#C4912A"/><stop offset="1" stop-color="#7E5712"/>
</linearGradient>
<linearGradient id="silver" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.16" stop-color="#EDEFF3"/><stop offset="0.46" stop-color="#CDD3DB"/><stop offset="0.72" stop-color="#9AA1AB"/><stop offset="1" stop-color="#63686F"/>
</linearGradient>
<radialGradient id="bgg" cx="0.34" cy="0.24" r="0.98">
<stop offset="0" stop-color="#3C3C45"/><stop offset="1" stop-color="#101012"/>
</radialGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<filter id="ds" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="2.5" stdDeviation="2.4" flood-color="#000000" flood-opacity="0.5"/></filter>
</defs>
<rect width="180" height="180" fill="url(#bgg)"/>
<rect width="180" height="180" fill="url(#sheen)"/>
<g filter="url(#ds)">
<path d="M90,90 C88,65 53,65 53,90 C53,115 88,115 90,90 C92,65 127,65 127,90 C127,115 92,115 90,90 Z" fill="none" stroke="url(#silver)" stroke-width="13"/>
<path d="M32,90 L47,90 L53,72 L61,108 L69,78 L77,102 L85,86 L90,93 L95,86 L103,102 L111,78 L119,108 L127,72 L133,90 L148,90" fill="none" stroke="url(#gold)" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/>
<circle cx="32" cy="90" r="3.6" fill="url(#gold)"/><circle cx="148" cy="90" r="3.6" fill="url(#gold)"/>
</g>
</svg>
```

- [ ] **Step 2: Author the C bold small variant**

Create `Tools/icon-gen/sources/brainwave-small.svg` (fatter loop + simpler, taller wave):

```svg
<svg width="1024" height="1024" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
<defs>
<linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFF6CE"/><stop offset="0.14" stop-color="#FCEAA0"/><stop offset="0.42" stop-color="#E6C055"/><stop offset="0.7" stop-color="#C4912A"/><stop offset="1" stop-color="#7E5712"/>
</linearGradient>
<linearGradient id="silver" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.16" stop-color="#EDEFF3"/><stop offset="0.46" stop-color="#CDD3DB"/><stop offset="0.72" stop-color="#9AA1AB"/><stop offset="1" stop-color="#63686F"/>
</linearGradient>
<radialGradient id="bgg" cx="0.34" cy="0.24" r="0.98">
<stop offset="0" stop-color="#3C3C45"/><stop offset="1" stop-color="#101012"/>
</radialGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
</defs>
<rect width="180" height="180" fill="url(#bgg)"/>
<rect width="180" height="180" fill="url(#sheen)"/>
<path d="M90,90 C87,62 50,62 50,90 C50,118 87,118 90,90 C93,62 130,62 130,90 C130,118 93,118 90,90 Z" fill="none" stroke="url(#silver)" stroke-width="16"/>
<path d="M30,90 L48,90 L56,66 L68,114 L80,72 L92,108 L104,74 L116,110 L124,90 L150,90" fill="none" stroke="url(#gold)" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
<circle cx="30" cy="90" r="5" fill="url(#gold)"/><circle cx="150" cy="90" r="5" fill="url(#gold)"/>
</svg>
```

- [ ] **Step 3: Generate the alternate**

Run: `python3 Tools/icon-gen/generate.py --only brainwave`
Expected: prints `generating: brainwave` then `done`.

- [ ] **Step 4: Verify, with emphasis on the 40px legibility**

Run:
```bash
for f in icon-40 icon-120 icon-1024; do sips -g pixelWidth -g hasAlpha "EchoCore/Assets.xcassets/AppIcon-Brainwave.appiconset/$f.png"; done
/opt/local/bin/rsvg-convert -w 40 -h 40 Tools/icon-gen/sources/brainwave-small.svg -o /tmp/c-small-40.png
/opt/local/bin/rsvg-convert -w 40 -h 40 Tools/icon-gen/sources/brainwave.svg -o /tmp/c-full-40.png
```
Expected: sizes correct, `hasAlpha: no`. Read both 40px PNGs — `c-small-40.png` must show a clear ∞ with a visible gold wave; if `c-full-40.png`'s thin wave vanishes, that confirms why the small variant exists. The shipped `icon-40.png` (from the small source) must match the legible one.

- [ ] **Step 5: Commit**

```bash
git add Tools/icon-gen/sources/brainwave.svg Tools/icon-gen/sources/brainwave-small.svg EchoCore/Assets.xcassets/AppIcon-Brainwave.appiconset
git commit -m "feat(icons): add Brainwave alternate with bold small variant"
```

---

### Task 8: Wire the new family into the picker

**Files:**
- Modify: `EchoCore/Views/AppIconSelectionView.swift:7-13`

- [ ] **Step 1: Replace the `icons` array**

In `EchoCore/Views/AppIconSelectionView.swift`, replace the array (currently lines 7–13):

```swift
        let icons: [(name: String, id: String?)] = [
            ("Default (Original)", nil),
            ("Complex Waves", "AppIcon-ComplexWaves"),
            ("Gold & Silver", "AppIcon-GoldSilver"),
            ("Silver & Gold", "AppIcon-SilverGold"),
            ("White Bolder", "AppIcon-WhiteBolder"),
        ]
```

with:

```swift
        let icons: [(name: String, id: String?)] = [
            ("Circuit Brain", nil),
            ("Hemisphere ∞", "AppIcon-HemisphereLoop"),
            ("Top-Down Brain", "AppIcon-TopDownBrain"),
            ("Brainwave", "AppIcon-Brainwave"),
            ("Classic Loop", "AppIcon-ClassicLoop"),
            ("Complex Waves", "AppIcon-ComplexWaves"),
            ("Gold & Silver", "AppIcon-GoldSilver"),
            ("Silver & Gold", "AppIcon-SilverGold"),
            ("White Bolder", "AppIcon-WhiteBolder"),
        ]
```

- [ ] **Step 2: Verify it compiles (lightweight syntax check)**

Run: `grep -n 'AppIcon-HemisphereLoop\|AppIcon-TopDownBrain\|AppIcon-Brainwave\|AppIcon-ClassicLoop' EchoCore/Views/AppIconSelectionView.swift`
Expected: four matches — each new alternate id is present and exactly matches its `.appiconset` directory name.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/AppIconSelectionView.swift
git commit -m "feat(icons): list the Mind icon family in the app icon picker"
```

---

### Task 9: `make icons` target + README + idempotency check

**Files:**
- Modify: `Makefile` (line 1 `.PHONY`; new target)
- Create: `Tools/icon-gen/README.md`

- [ ] **Step 1: Add `icons` to `.PHONY` and a target**

In `Makefile`, append `icons` to the `.PHONY` list on line 1, then add (matching the `@`-prefixed, `## help-comment`, repo-root-relative style of the existing `architecture` target):

```make
icons: ## Regenerate all app-icon PNGs (iOS/macOS/Watch/Widget) from Tools/icon-gen/sources/*.svg
	@python3 Tools/icon-gen/generate.py
	@echo "App icons regenerated — review git diff in *.xcassets before committing."
```

- [ ] **Step 2: Author the README**

Create `Tools/icon-gen/README.md`:

```markdown
# Echo app-icon generator

Master art lives in `sources/*.svg` (a 180-unit design grid; rendered to any
pixel size). `generate.py` rasterizes them into the asset catalogs.

## Run

    make icons                      # regenerate everything
    python3 Tools/icon-gen/generate.py --only default hemisphere topdown brainwave

## Rules (verified for this machine)

- **Rasterizer:** `rsvg-convert` ONLY. ImageMagick has no librsvg delegate here
  and renders SVGs as flat black; it is used only to flatten alpha on PNGs.
- **No `transform-origin`** — rsvg ignores it. Bake pivots with
  `translate(cx,cy) scale(s) translate(-cx,-cy)`.
- **iOS/Watch/Widget:** full-bleed square, no alpha (flattened), no baked corners.
- **macOS:** RGBA with a baked rounded-squircle + margin + shadow (`*-macos.svg`).
- Only the default (Circuit Brain) ships to macOS/Watch/Widget; A/B/C are iOS-only
  alternates. B and C carry a bold `*-small.svg` used at/below 120px.

## Adding an alternate

1. Add `sources/<name>.svg` (full-bleed).
2. Add a `gen_*` function + `TARGETS` entry in `generate.py`.
3. Run the generator; add a `("Display Name", "AppIcon-<Name>")` tuple to
   `EchoCore/Views/AppIconSelectionView.swift`.
```

- [ ] **Step 3: Verify `make icons` regenerates with no diff (idempotency)**

Run:
```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --status >/dev/null 2>&1 || true
make icons
git status --porcelain -- '*.xcassets'
```
Expected: `make icons` completes printing the regeneration notice; `git status` shows NO changes under `*.xcassets` (deterministic output — re-rendering the same SVGs reproduces identical PNGs). If there is a diff, the generator is non-deterministic — investigate before proceeding.

- [ ] **Step 4: Commit**

```bash
git add Makefile Tools/icon-gen/README.md
git commit -m "build(icons): add make icons target and generator README"
```

---

### Task 10: Build verification + docs sync

**Files:**
- Modify: `README.md` (alternate-icons note, if present)
- Modify: `ARCHITECTURE.md` (tooling note, if a tooling section exists)

- [ ] **Step 1: Compile the asset catalogs via a gated build**

Run (single build, gated, signing off per repo convention):
```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```
Expected: build succeeds. Scan the log for asset-catalog issues:
```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests 2>&1 | grep -iE 'appicon|asset|alpha|icon' | grep -iE 'error|warning' || echo "no icon asset warnings"
```
Expected: `no icon asset warnings` (no missing-size, wrong-dimension, or alpha-in-iOS-icon warnings). If a warning appears, fix the offending appiconset/source and re-run the relevant generator task.

- [ ] **Step 2: (Optional but recommended) Simulator smoke test of the picker**

Boot a sim, run the app, open Settings → App Icon, switch to each alternate, and confirm the Home-Screen icon changes and the checkmark tracks. (Use the simulator-tester agent or `xcui`.) Capture a screenshot of the Home Screen showing the new Circuit Brain default at true size.

- [ ] **Step 3: Sync documentation**

Update `README.md` if it mentions the alternate icons / icon set, to describe the new Mind family (Circuit Brain default + Hemisphere ∞ / Top-Down Brain / Brainwave / Classic Loop + the four legacy variants) and the `make icons` pipeline. If `ARCHITECTURE.md` has a tooling/Scripts section, add a one-line entry for `Tools/icon-gen`. (Per repo convention, surface this doc change explicitly.)

- [ ] **Step 4: Commit**

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs(icons): document the Mind icon family and make icons pipeline"
```

---

## Self-Review

**Spec coverage:**
- Family (D default + A/B/C) → Tasks 2,5,6,7. Classic Loop preservation → Task 1. Legacy kept → Task 8 (array retains all four). ✓
- SVG→PNG pipeline / `make icons` → Tasks 2,9. ✓
- Bold small variants for B & C → Tasks 6,7 (`gen_ios_matrix`, `*-small.svg`, 120px breakpoint). ✓
- Per-target framing (iOS/Widget/Watch full-bleed no-alpha; macOS RGBA squircle) → Tasks 2,3,4 + `render(keep_alpha=...)`. ✓
- Watch repoint → Task 4. Picker wiring → Task 8. No Info.plist editing (INCLUDE_ALL) → relied on, not edited. ✓
- Verification (dimensions/alpha/visual/build) → every task + Task 10. Docs sync → Task 10. ✓

**Placeholder scan:** No TBD/TODO; every SVG and the generator are given in full; commands have expected output. ✓

**Type/name consistency:** appiconset names (`AppIcon-HemisphereLoop`, `AppIcon-TopDownBrain`, `AppIcon-Brainwave`, `AppIcon-ClassicLoop`) match across generator `gen_*`, picker tuples (Task 8), and verification greps. Generator helpers (`render`, `gen_ios_universal`, `gen_ios_matrix`, `gen_macos`, `gen_watch`, `write_contents`) defined in Task 2 and used consistently. `SMALL_BREAKPOINT_PX = 120` matches the spec's ≤120px rule. ✓

**Known follow-ups (not blocking, noted for the implementer):** per-row thumbnail previews in the picker; iOS 18 dark/tinted icon appearance variants — both deliberately out of scope per the spec.
