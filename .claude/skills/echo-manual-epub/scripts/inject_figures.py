#!/usr/bin/env python3
"""Insert the placeholder figures into the chapter files at sensible paragraph boundaries.

Reads <build>/figures.json (written by generate_placeholders.py), groups figures by
chapter, and inserts a standalone `![caption](imgNN.png)` line after evenly-spaced
prose paragraphs in each <build>/chapters/chNN.md — never the title line, never a
`---` divider, never the final block, and never the first paragraph (so a figure
always follows real context). Writers produce pure spoken prose with NO image
markup; figures are injected here so the narrated track stays clean and figure
syntax never pollutes the word-count or code-leak QC.

Idempotent: strips any existing image lines first, so it can be re-run safely.

Usage:  python3 inject_figures.py --build-dir /path/to/build
"""

import argparse
import json
import os
import re

HR_RE = re.compile(r"^([-*_]\s*){3,}$")
IMG_RE = re.compile(r"^!\[.*\]\(.*\)$")


def main():
    ap = argparse.ArgumentParser(description="Inject placeholder figures into the Echo manual chapters.")
    ap.add_argument("--build-dir", default=os.getcwd())
    a = ap.parse_args()
    ch_dir = os.path.join(a.build_dir, "chapters")

    with open(os.path.join(a.build_dir, "figures.json"), encoding="utf-8") as f:
        figs = json.load(f)
    by_ch = {}
    for fig in figs:
        by_ch.setdefault(fig["chapter"], []).append(fig)

    for ch, items in sorted(by_ch.items()):
        path = os.path.join(ch_dir, "ch%02d.md" % ch)
        if not os.path.exists(path):
            print("skip (no file):", path)
            continue
        with open(path, encoding="utf-8") as f:
            raw = f.read().strip()
        blocks = [b.strip() for b in re.split(r"\n\s*\n", raw) if b.strip()]
        blocks = [b for b in blocks if not IMG_RE.match(b)]

        cands = [i for i in range(1, len(blocks) - 1)
                 if not HR_RE.match(blocks[i]) and not blocks[i].startswith("#")]
        if len(cands) > 2:
            cands = cands[1:]

        k = len(items)
        if not cands:
            chosen = []
        else:
            chosen = []
            for j in range(k):
                pos = int(round((j + 1) * len(cands) / (k + 1))) - 1
                pos = max(0, min(pos, len(cands) - 1))
                chosen.append(cands[pos])
            seen, uniq = set(), []
            for c in chosen:
                while c in seen and c + 1 < len(blocks) - 1:
                    c += 1
                seen.add(c)
                uniq.append(c)
            chosen = uniq

        insert_after = {idx: items[n] for n, idx in enumerate(chosen)}
        out = []
        for i, b in enumerate(blocks):
            out.append(b)
            if i in insert_after:
                fig = insert_after[i]
                out.append("![%s](%s)" % (fig["caption"], fig["file"]))
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n\n".join(out) + "\n")
        print("ch%02d: inserted %d/%d figures at blocks %s"
              % (ch, len(chosen), k, sorted(chosen)))


if __name__ == "__main__":
    main()
