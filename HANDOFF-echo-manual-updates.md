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
