#!/usr/bin/env python3
"""Generate captioned placeholder 'screenshot' images for the Welcome to Echo manual.

Each figure is a device-shaped placeholder card. The card renders the SHOT
description (what the real screenshot should show) into the pixels, so whoever
swaps in the real screenshot later knows exactly what to capture. The short,
narration-safe CAPTION is what the EPUB shows under the image / passes to alt
text — defined here too and emitted as figures.json for the figure injector.

Renders SVG -> PNG via rsvg-convert (falls back to ImageMagick magick/convert).

FIGURES below is the single source of truth for the manual's screenshots — edit
it (add/remove/retarget per chapter), re-run, then re-run inject_figures.py and
rebuild. Keep captions short and narration-safe (Echo may read them aloud); put
the detailed "what to shoot" guidance in the shot field, which lives only in the
placeholder pixels.

Usage:  python3 generate_placeholders.py --build-dir /path/to/build
        (writes <build>/images/*.png and <build>/figures.json)
"""

import argparse
import html
import json
import os
import shutil
import subprocess
import textwrap

# Palette (warm paper + indigo accent, echoing Echo's tonal look)
PAPER = "#F3EFE6"
CARD = "#FBF9F4"
INK = "#2A2722"
MUTE = "#7A7468"
ACCENT = "#4C5BD4"
ACCENT_SOFT = "#E4E6FA"
LINE = "#C9C2B4"

# shape -> (width, height) in px
SHAPES = {
    "phone": (760, 1340),
    "watch": (760, 900),
    "mac": (1180, 760),
    "wide": (1180, 720),
}

# Each figure: id, chapter, shape, caption (short, narration-safe -> EPUB),
# shot (what to photograph -> rendered into the placeholder).
# Second edition (2026-08): 17-chapter map. Real-capture plan: phone shots come
# from the iPhone 17 simulator with Load Development Assets; mac shots from the
# Mac app. Files-app, watch, and Audiobookshelf shots stay placeholders.
FIGURES = [
    ("img00", 0, "phone", "Echo's three tabs: Now Playing, Read and Study, and Library.",
     "App with a book loaded and playing; the bottom dock with the mini player, and the tab bar showing Now Playing, Read & Study, and Library."),
    ("img01", 1, "phone", "Choosing Load Folder and picking a book's folder.",
     "The import flow: the Library empty state or Load Folder tapped, with the system folder picker open on an Audiobooks folder."),
    ("img02", 1, "phone", "The Now Playing screen right after a book loads.",
     "Now Playing just after import: cover art, cover-tinted wash, chapter title, scrubber, five transport buttons."),
    ("img03", 1, "phone", "Browsing an Audiobookshelf server from inside Echo.",
     "PLACEHOLDER OK: ABS browse screen with sort/filter chips and a download card showing honest stages (Downloading, Extracting, Validating, Adding to Echo)."),
    ("img04", 2, "phone", "One parent folder, one folder per book, ebook beside the audio.",
     "PLACEHOLDER OK (Files app): Audiobooks/ with per-book subfolders; one open showing the m4b, the epub, and cover.jpg together."),
    ("img05", 2, "phone", "One book, one card: audio and ebook editions grouped together.",
     "Library shelf card context menu: sibling editions listed, 'Use as Read-Along Text' and 'Separate This Edition' visible."),
    ("img06", 2, "phone", "Long-press a folder and choose Keep Downloaded.",
     "PLACEHOLDER OK (Files app): long-press menu on the Audiobooks folder with 'Keep Downloaded' highlighted; a cloud icon on an evicted file."),
    ("img07", 3, "phone", "Transport buttons, the speed control, and scrubber tick marks.",
     "Now Playing close-up: transport row, chapter chevrons, speed at 1.25x, chapter tick marks on the scrubber."),
    ("img08", 3, "phone", "Assigning tap and long-press actions to each button.",
     "Settings > Controls > Phone Player Settings: five button slots with tap and long-press action pickers."),
    ("img09", 3, "phone", "Visual Listening: a book with pictures becomes a slideshow.",
     "Now Playing in the Visual Listening stage: the active figure or code card, its caption, and word-by-word highlighted text beneath."),
    ("img10", 4, "phone", "Smart Rewind's three tiers, from a short pause to days away.",
     "Settings > Now Playing > Playback Defaults > Smart Rewind: three tiers (seconds, minutes, hours-to-days) with their rewind amounts."),
    ("img11", 5, "phone", "Loop modes: chapter, between bookmarks, or off.",
     "The Playback Options sheet with the loop-mode selector showing Off / Chapter / Bookmark, 'Chapter' selected."),
    ("img12", 5, "phone", "A bookmark's editor: title, note, voice memo, and an attached image.",
     "Edit Bookmark sheet: title, time, note field, live voice-memo recording row, and the Attach Image row."),
    ("img13", 6, "phone", "The reader feed following the narration, active paragraph lit.",
     "Read & Study tab mid-playback: accordion feed with the playing chapter expanded, one paragraph highlighted, the 'Return to current text' button visible."),
    ("img14", 6, "phone", "Reader typography: Lexend, OpenDyslexic, size, spacing, tint.",
     "Reader settings: font picker (Lexend, OpenDyslexic), text size, line spacing, and card tint."),
    ("img15", 6, "phone", "A PDF in page view, highlighting the spoken word on the page.",
     "PDF page view mid-playback: the active word highlighted on the page, with the Look Up / Save Word menu open on a pressed word."),
    ("img16", 7, "phone", "Auto-Align Chapters running on-device.",
     "Auto-alignment progress view: pass list (title match, chapter snap, drift detection, drift repair), progress bar, percent aligned."),
    ("img17", 7, "phone", "Long-press a paragraph to lock a manual anchor.",
     "Reader paragraph menu with 'Align to Now' and 'Align to 5s Ago'; a green anchor badge on a locked paragraph."),
    ("img18", 8, "phone", "Letting Echo narrate a text-only book on your device.",
     "Narration setup for a text-only EPUB: the Narrate control and the voice picker (default Ava)."),
    ("img19", 8, "phone", "The status card telling the honest truth about a render.",
     "The narration status card mid-render: stage (rendering), render-ahead buffer, expanded timestamped history beneath."),
    ("img20", 8, "phone", "The chapter outline — tap a chapter to skip narrating it.",
     "Narration chapter outline listing every chapter; one greyed out with a speaker-slash icon to mark it excluded."),
    ("img21", 9, "phone", "The Article Inbox: web articles saved as private snapshots.",
     "Article Inbox in the Library tab: several captured articles with thumbnails, and an anthology draft being assembled."),
    ("img22", 9, "mac", "The Mac Article Workshop: collect all week, listen on the phone.",
     "Mac Article Workshop: captured articles list, paste-links anthology builder, per-piece narration voice pickers."),
    ("img23", 10, "phone", "Daily Review: hear the card, then grade yourself.",
     "Daily Review card with a play button for the audio snippet and four grade buttons: Again, Hard, Good, Easy."),
    ("img24", 10, "phone", "Creating a flashcard from a passage in the reader.",
     "Reader passage long-press 'Create Flashcard', then the card editor with front, back, and an audio-snippet range."),
    ("img25", 10, "phone", "AI card generation: three flavours, all opt-in.",
     "Settings > Study & Notes > AI Card Generation: the provider picker (auto, cloud with your own key, on-device) and a generated-cards review list."),
    ("img26", 11, "phone", "The Card Inbox — marked passages, one tap from a card.",
     "Card Inbox grouped by book; each mark shows its transcript snippet and audio, with convert/dismiss swipe actions."),
    ("img27", 11, "phone", "The bookmark button's menu: a bookmark, a note, or a voice memo — without pausing.",
     "The dock bookmark button's menu open over the reader feed: Add bookmark / Add note / Record memo."),
    ("img28", 12, "phone", "Stats: your listening and studying, computed on your device.",
     "The Stats sheet: overview with range picker, total time, streak, a listening chart, and the study section's retention curve and due forecast."),
    ("img29", 12, "phone", "Sessions: a diary of every listen.",
     "Sessions history list: past sessions with date, duration, chapter range, captures; one tapped to show its recap."),
    ("img30", 13, "phone", "Exporting a book as one chaptered audiobook file.",
     "The export flow: More menu > Export Audiobook, then the share sheet with the finished m4b file."),
    ("img31", 13, "phone", "Exporting the slideshow as a video, tall or wide.",
     "Export Video options: landscape and portrait choices, with a preview frame showing figure, caption, and karaoke subtitle."),
    ("img32", 14, "watch", "The Apple Watch remote — big, glanceable buttons.",
     "PLACEHOLDER OK (watch): remote grid with large buttons (play, skips, loop, bookmark) and segmented chapter progress capsules."),
    ("img33", 14, "phone", "Designing the watch layout from your phone.",
     "Settings > Controls > Watch App Settings: five pages of five labelled slot pickers, each slot assigned an action."),
    ("img34", 15, "mac", "Echo for Mac: library, reader, and study panes in one window.",
     "Mac three-pane window: library and chapters sidebar left, reader center, transcript/review/notes and synced bookmarks right, player footer."),
    ("img35", 16, "phone", "Echo Pro: a one-time unlock, never a subscription.",
     "The Echo Pro sheet: a single one-time purchase with real prices, visible Restore, and the free-tier limits listed (20 cards, 1 narrated chapter per book)."),
]


def esc(s):
    return html.escape(s, quote=True)


def wrap_lines(text, width):
    out = []
    for para in text.split("\n"):
        out.extend(textwrap.wrap(para, width=width) or [""])
    return out


def svg_for(fig):
    fid, ch, shape, caption, shot = fig
    W, H = SHAPES[shape]
    pad = 46
    fx, fy = pad, pad
    fw, fh = W - 2 * pad, H - 2 * pad
    radius = 54 if shape in ("phone", "watch") else 26

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">']
    parts.append(f'<rect width="{W}" height="{H}" fill="{PAPER}"/>')
    parts.append(f'<rect x="{fx}" y="{fy}" width="{fw}" height="{fh}" rx="{radius}" ry="{radius}" '
                 f'fill="{CARD}" stroke="{LINE}" stroke-width="3"/>')

    inner_x = fx + 34
    inner_w = fw - 68
    cy = fy + 40
    if shape in ("phone", "watch"):
        parts.append(f'<rect x="{fx + fw/2 - 60}" y="{fy + 22}" width="120" height="14" rx="7" fill="{LINE}"/>')
        cy = fy + 74

    pill_w = 360
    pill_x = fx + fw/2 - pill_w/2
    parts.append(f'<rect x="{pill_x}" y="{cy}" width="{pill_w}" height="48" rx="24" fill="{ACCENT_SOFT}"/>')
    parts.append(f'<text x="{fx + fw/2}" y="{cy + 32}" text-anchor="middle" '
                 f'font-family="Helvetica, Arial, sans-serif" font-size="22" font-weight="700" '
                 f'letter-spacing="2" fill="{ACCENT}">SCREENSHOT PLACEHOLDER</text>')
    cy += 86

    gx = fx + fw/2
    parts.append(f'<g transform="translate({gx - 44},{cy})" fill="none" stroke="{ACCENT}" stroke-width="5" '
                 f'stroke-linejoin="round" stroke-linecap="round">'
                 f'<rect x="0" y="14" width="88" height="62" rx="12"/>'
                 f'<path d="M26 14 L34 2 L54 2 L62 14"/>'
                 f'<circle cx="44" cy="46" r="20"/></g>')
    cy += 110

    box_x, box_y, box_w = inner_x, cy, inner_w
    box_h = fy + fh - 150 - box_y
    parts.append(f'<rect x="{box_x}" y="{box_y}" width="{box_w}" height="{box_h}" rx="18" '
                 f'fill="none" stroke="{ACCENT}" stroke-width="2.5" stroke-dasharray="10 9"/>')

    tx, ty = box_x + 30, box_y + 56
    parts.append(f'<text x="{tx}" y="{ty}" font-family="Helvetica, Arial, sans-serif" font-size="22" '
                 f'font-weight="700" fill="{MUTE}" letter-spacing="1">WHAT TO SHOW</text>')
    ty += 46

    char_w = 30 if shape == "mac" else 26
    fs = 30 if shape != "watch" else 28
    lh = fs + 14
    for line in wrap_lines(shot, char_w):
        parts.append(f'<text x="{tx}" y="{ty}" font-family="Georgia, \'Times New Roman\', serif" '
                     f'font-size="{fs}" fill="{INK}">{esc(line)}</text>')
        ty += lh

    fy2 = fy + fh - 60
    parts.append(f'<text x="{fx + fw/2}" y="{fy2}" text-anchor="middle" '
                 f'font-family="Helvetica, Arial, sans-serif" font-size="20" fill="{MUTE}">'
                 f'Echo &#183; Welcome to Echo manual &#183; {esc(fid)} &#183; ch{ch:02d}</text>')
    parts.append('</svg>')
    return "\n".join(parts)


def render(svg_path, png_path):
    if shutil.which("rsvg-convert"):
        subprocess.run(["rsvg-convert", "-o", png_path, svg_path], check=True)
    elif shutil.which("magick"):
        subprocess.run(["magick", "-background", "none", svg_path, png_path], check=True)
    elif shutil.which("convert"):
        subprocess.run(["convert", "-background", "none", svg_path, png_path], check=True)
    else:
        raise SystemExit("No SVG rasterizer found (need rsvg-convert or ImageMagick).")


def main():
    ap = argparse.ArgumentParser(description="Generate placeholder screenshots for the Echo manual.")
    ap.add_argument("--build-dir", default=os.getcwd(),
                    help="Build directory (writes <build>/images/*.png and <build>/figures.json)")
    a = ap.parse_args()
    out = os.path.join(a.build_dir, "images")
    os.makedirs(out, exist_ok=True)

    manifest = []
    for fig in FIGURES:
        fid, ch, shape, caption, shot = fig
        svg_path = os.path.join(out, fid + ".svg")
        png_path = os.path.join(out, fid + ".png")
        with open(svg_path, "w", encoding="utf-8") as f:
            f.write(svg_for(fig))
        render(svg_path, png_path)
        os.remove(svg_path)
        manifest.append({"id": fid, "chapter": ch, "file": fid + ".png",
                         "caption": caption, "shot": shot})
        print("rendered", png_path)
    with open(os.path.join(a.build_dir, "figures.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    print("\nWrote", len(manifest), "placeholders + figures.json")


if __name__ == "__main__":
    main()
