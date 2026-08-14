# Handoff — Echo manual second edition + beta guide + screenshots

## 2026-08-13 — Beta guide shipped; chapters writing

Done: TestFlight beta guide refreshed → PR #555 (nightly). Fact packs at
~/Developer/echo-manual-build/welcome-to-echo/factpacks-2026-08-13.md.
Chapters ch00–ch11 written (~3k words each); ch12–ch16 writers running.
FIGURES list rewritten (36 figures, committed 33a3fd59); placeholders +
figures.json regenerated; dist/cover.png staged (= June cover-1.png).
Next: QC all 17 → inject figures → build EPUB → deliver to
~/Downloads/book-inbox/. Then task #6: real screenshots (build slot opens
22:00; iPhone 17 sim + Load Development Assets; Files/watch/ABS stay
placeholders).
Resume:
```
Worktree .claude/worktrees/echo-manual-updates-3e9128, branch
claude/echo-manual-updates-3e9128. Manual build dir
~/Developer/echo-manual-build/welcome-to-echo. If chapters ch12–ch16 are
present and ≥2,700 words: run skill QC greps, inject_figures.py,
build_book_images.py (--contributor "Fable 5"), deliver EPUB.
```

## 2026-08-13 — EPUB built and delivered (placeholder figures)

Done: All 17 chapters QC'd (2 fixes: ch07 auto-align trigger, ch14 banned
phrase). Figures injected (36). EPUB built: 51,707 words, ~5.7 h, mimetype 0
verified; delivered to ~/Downloads/book-inbox/ + sent to Dan with the
Markdown. Cover = June cover-1.png (Aug-11 concepts remain alternates).
Next: task #6 real screenshots after 22:00 slot — build Debug for iPhone 17
sim via xcode-build-slot.sh, Load Development Assets, capture per
figures.json "shoot" notes; Mac shots from Mac app; watch/Files/ABS stay
placeholders. Then overwrite imgNN.png in images/ and rebuild + redeliver.
Resume:
```
Worktree .claude/worktrees/echo-manual-updates-3e9128. Build dir
~/Developer/echo-manual-build/welcome-to-echo (EPUB done, placeholders).
Next action: after 22:00, xcode-build-slot.sh sim Debug build → capture
real screenshots per images/figures.json → replace imgNN.png → rerun
build_book_images.py → recopy to ~/Downloads/book-inbox/.
```

## 2026-08-13 late — Real screenshots in, second edition rebuilt + delivered
Done: 24/36 real figures (23 sim + 1 Mac window); fixed invented "loop
playlist" + "capture bar" + wrong Mac pane layout in ch05/ch11/ch14/ch15,
captions, figures.json, skill FIGURES; EPUB rebuilt (51,718 w, mimetype 0),
delivered to ~/Downloads/book-inbox/ + sent; beta-guide fix PR #556 (open);
crash chips: Article Workshop (task_c20e89fc), Review Queue (task_61df588b).
Next: 12 placeholders remain (img03/04/05/06/09/15/21/22/23/29/32/35) —
most need env fixes (App Group, watch, ABS) or the two crash fixes first.
Resume:
```
Worktree .claude/worktrees/echo-manual-updates-3e9128, branch
claude/echo-manual-updates-3e9128. Manual done + delivered. Next action:
none pending here — merge PR #556, then close this task branch.
```
