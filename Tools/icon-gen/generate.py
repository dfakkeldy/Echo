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
