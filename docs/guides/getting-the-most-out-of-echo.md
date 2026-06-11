# Getting the Most Out of Echo

Echo isn't just an audiobook player with extra buttons. Every feature exists because of something specific we know about how human memory works. This guide walks through each one: what it does, the science behind why it helps, and how to actually use it.

You don't need to read this front to back. Jump to whatever feature you're curious about — each section stands on its own.

> **Status tags:** 🚧 **Coming in 1.0** = in active development right now. 🔭 **Roadmap** = planned after 1.0. Everything unmarked ships in the current beta. Looking for ADHD/AuDHD-specific strategies? See the [Focus Field Guide](focus-field-guide.md).

> **The short version:** Passive listening feels like learning, but most of it evaporates within days. Echo is built around the handful of techniques that cognitive science has shown actually move information into long-term memory: retrieval practice, spacing, context cues, cognitive offloading, and multi-sensory encoding. Use even two or three of them and you will remember dramatically more of what you listen to.

---

## 1. Photo & Place Bookmarks — borrow your brain's sense of place

**What it does:** When you create a bookmark, you can attach a photo — snap something around you or pick one from your photo library. Later, as playback passes that bookmark, Echo switches the player artwork to your photo. Your bookmarks become a visual journal of the book, and each photo becomes a doorway back to what you were hearing.

**The science: Context-Dependent Memory.** Your brain doesn't file information away in isolation — it *involuntarily* encodes the environment you're in right alongside the thing you're learning. When you return to that environment, or even just see a picture of it, the environment acts as a retrieval cue that pulls the information back up.

This is one of the most replicated effects in memory research. In the classic 1975 study by Godden and Baddeley, scuba divers memorized word lists either on land or underwater — and recalled significantly more when tested in the *same* environment they learned in. A large meta-analysis (Smith & Vela, 2001) confirmed the effect across dozens of studies — and crucially, found that *mentally reinstating* a context (like looking at a photo of it) recovers much of the benefit of physically being there.

You've probably felt this yourself: you remember exactly what audiobook you were listening to when you drove past that one weird intersection — and you'd never have remembered the intersection without the book, or the book without the intersection. The two memories hold each other up. Echo turns that accident into a tool.

### Context Memory: places, captured automatically — 🚧 Coming in 1.0

Photo bookmarks ask you to do the capturing. **Context Memory** does it for you: opt in, and Echo quietly notes an approximate place — "Maple Ridge, Halifax" — on your bookmarks, listening sessions, and chapter starts. Bookmark cards grow a small place chip; your per-book insights can tell you *"you started Chapter 3 on Oak Street."* The same retrieval-cue machinery as photos, with zero effort.

- **Off by default, on-device, deletable.** Location uses reduced (neighborhood-level) accuracy, never blocks the action you were taking, and a single button erases all location history. Your session history never leaves the device.
- **Use the chips during review.** When a bookmark shows "Riverside Trail," take one second to put yourself back on that trail before answering. That mental reinstatement is the technique — the chip is just the trigger.

**How to use it:**
- When something in a book genuinely lands, bookmark it and grab a photo of wherever you are — the trailhead, your kitchen, the view out the windshield (when parked!). Mundane is fine; *distinctive* is better.
- Driving or working? Don't break focus. Attach a photo later from your photo library — a picture taken near that time and place works almost as well. (Or let Context Memory log the place automatically.)
- During flashcard review, when the photo appears, take a second to mentally *put yourself back there* before answering. That deliberate reinstatement is what fires the retrieval cue.
- Don't photograph everything. A photo on every paragraph is noise; a photo on the ten ideas you most want to keep is a memory palace.

> **Is this a "memory palace"?** Close cousin. The memory palace (method of loci) deliberately places facts into an imagined space; Echo's photo and place bookmarks capture the *real* space your brain already attached to the moment. Same spatial machinery — brain-imaging studies of champion memorizers (Maguire et al., 2003) show they lean on exactly these spatial-memory regions — but with zero effort, because your hippocampus was doing it anyway.

---

## 2. The Study System — spaced repetition, explained from zero

**What it does:** Echo has a built-in flashcard system. Any bookmark, passage, or note can become a card with a front (the prompt) and a back (the answer) — and cards can carry the actual audio clip from the book. Echo schedules reviews for you: a card you know well disappears for weeks; a card you fumbled comes back tomorrow. Your due cards show up in a Daily Review queue on your phone — and on your wrist.

**Never heard of Anki? Start here.** Anki is beloved flashcard software used by medical students, language learners, and memory nerds worldwide. Its superpower is the *schedule*: instead of cramming, it shows you each card at the moment you're about to forget it — first after a day, then a few days, then weeks, then months. Each successful recall flattens your forgetting curve a little more, until the fact is effectively permanent.

Echo speaks the same language — it uses the same SM-2 scheduling algorithm Anki was built on, imports Anki-style JSON decks today, and with 1.0 imports real **.apkg deck files** directly (🚧 Coming in 1.0) — your years of Anki history, scheduling included, carried over. Organize everything into **decks with tags**, edit any card, review one deck at a time (🚧 Coming in 1.0). And if you ever leave, your cards export right back out — no lock-in (see [Second-Brain Export](#12-second-brain-export--make-it-yours-forever---coming-in-10)).

**The science: the Forgetting Curve and the Spacing Effect.** In the 1880s, Hermann Ebbinghaus measured how quickly memorized material decays: steeply at first — most of it within days — then slowly. He also found the fix: each well-timed review resets the curve and makes it shallower. A century-plus of follow-up research (including a major meta-analysis by Cepeda and colleagues in 2006) keeps confirming it: **spacing reviews out beats massing them together, for essentially everyone, for essentially everything.**

**Why audio flashcards beat paper ones:**
- **Two memory channels instead of one.** Hearing the narrator's clip while reading the card engages both verbal and auditory encoding — and if you attached a photo, a visual cue too. More routes in, more routes back out.
- **Matching cue and memory.** You learned the material *by ear*. Reviewing it by ear matches the retrieval cue to how the memory was encoded — the encoding-specificity principle (Tulving & Thomson, 1973).
- **Review happens in dead time, not desk time.** What kills flashcard habits isn't difficulty — it's needing to sit down. Echo reviews ride along while you walk the dog or wait in the car, including hands-free on Apple Watch. The best study system is the one that fits inside the life you already have.

**How to use it:**
- Make cards from *meaningful* moments: definitions, frameworks, numbers you'll need. Skip trivia.
- Write fronts as questions ("What are the four causes of X?"), not labels. A question forces retrieval; a label invites recognition.
- Do your Daily Review when the notification arrives. Five minutes daily beats an hour monthly — that's the whole point of spacing.
- Trust the schedule. Re-reviewing cards that aren't due is the cramming instinct — the exact thing the system is saving you from.
- Bringing decks from Anki? Import the .apkg and keep your scheduling — don't restart mature cards from zero. (🚧 Coming in 1.0)

---

## 3. Honest Grading — the testing effect

**What it does:** After each flashcard, Echo asks you to grade yourself: **Again, Hard, Good, or Easy**. Your answer drives the schedule.

**The science: Retrieval Practice.** Testing isn't just measurement — it's the intervention. Roediger & Karpicke's landmark 2006 studies showed that students who *practiced recalling* material remembered far more a week later than students who spent the same time re-reading it — even though re-reading *felt* more effective. The struggle to pull something from memory is what strengthens it.

- Before flipping a card, actually answer it — out loud or in your head. *Then* look.
- Grade ruthlessly. "Again" is not failure; it's telling the scheduler the truth so it can help. An over-graded card disappears for a month and takes the memory with it.
- Feeling a card was *hard* is good news. Effortful retrieval — what researcher Robert Bjork calls a "desirable difficulty" — is exactly the condition under which memory grows.

---

## 4. Mark Now, Card Later — protect the flow — 🚧 Coming in 1.0

**What it does:** A single tap — on the transport bar or a watch button — **marks** the passage you just heard, with a few seconds of context on either side, and the narration never stops. Later, your **Card Inbox** shows every mark grouped by book, with its transcript snippet and audio. Turn marks into flashcards when you actually have the bandwidth — or swipe away the ones that didn't age well.

**The science: Attention Residue.** Switching tasks isn't free, even for "just a second." Sophie Leroy's research on *attention residue* (2009) shows that part of your attention stays stuck on an interrupted task after you switch — and interruption studies (Monk, Trafton & Boehm-Davis, 2008) show the cost grows with the interruption's length and depth. Stopping a book mid-argument to type a flashcard is exactly the kind of deep interruption that leaves residue in both directions. A one-tap mark is the shallowest possible interruption: capture intent now, do the work when switching costs nothing.

- Mark generously, convert selectively. The tap costs nothing; the inbox is where judgment happens.
- Batch your inbox at a set time — end of the listening day, or Sunday with coffee. Converting five marks in a row is faster (and produces better cards) than five mid-listen scrambles.
- While converting, the snippet replays the narrator. Write the front as a question *before* replaying — that's a free retrieval rep.

> 📸 *Screenshot coming soon — the Card Inbox: marked passages grouped by book, one tap from flashcard.*

---

## 5. Brain Dump — close the open loop — 🚧 Coming in 1.0

**What it does:** A thought hits you mid-chapter — about the book, or about absolutely anything else ("buy stamps," "that's what Sarah meant on Tuesday"). One tap opens a note; hold to record a voice memo; on the watch, dictate it. Playback never pauses. The thought lands in the book's **Notes inbox** (or your global one), and later you can **promote** the keepers into bookmarks or flashcards — or just enjoy having had the thought without losing the chapter.

**The science: the Zeigarnik Effect & Cognitive Offloading.** Unfinished business doesn't wait quietly. Bluma Zeigarnik documented in 1927 that interrupted, incomplete tasks are remembered better — and intrude more — than completed ones. Masicampo & Baumeister (2011) found the modern fix: you don't have to *do* the nagging task to silence it — merely **making a concrete plan** (or capturing it somewhere you trust) stops it from hijacking attention. And working memory is brutally small — roughly three to five items at once (Cowan, 2010) — so every "don't forget…" you carry is a slot stolen from the book. Offloading to an external store (Risko & Gilbert, 2016) hands the thought to something that never forgets, and frees the slot.

- **Capture in the cheapest format available.** Walking? Voice. Watch on? Dictate. The format doesn't matter; latency does. The thought you capture in two seconds is the thought that doesn't cost you a paragraph.
- **Dump distractions, not just insights.** "Email the landlord" has no business in your head during chapter 6. Park it, return to the book, act on it tonight.
- **Process the inbox on your schedule.** Promote book-thoughts to bookmarks or cards; export errands to wherever errands live; delete freely. An inbox you trust only stays trusted if it empties sometimes.

> 📸 *Screenshot coming soon — Brain Dump notes inbox with text and voice entries, promote actions visible.*

---

## 6. Chapter Looping — repetition on your terms

**What it does:** Echo can loop a single chapter until you turn looping off — the feature this entire app was born from. Loop the whole playlist, one chapter, or the exact passage between two bookmarks.

**The science: Repetition, then Distribution.** Hearing dense material once at highway speed is not learning — repetition genuinely helps build the representation. But research on *distributed practice* shows the bigger win is spreading exposures out: three passes over three days beat six passes in one afternoon. Loop a chapter today; let your flashcards and scheduled reviews carry it across the week.

- For a book you need to *know*: loop one or two chapters per day rather than racing to the end. Six hours of driving = one chapter genuinely absorbed beats six chapters vaguely heard.
- End of a looped day, ask the honest question: could you teach this chapter? If not, tomorrow is another loop day.
- Drop a bookmark at the start and end of a key argument, switch to **loop between bookmarks**, and drill exactly that stretch.

> **🔭 Roadmap — Chapter Study Mode.** Planned after 1.0: treat *each chapter as a flashcard*. Finish a chapter, grade yourself — Again or Easy — and Echo schedules that chapter's return; your due chapters become a ready-made listening queue. Until then, the manual version works today: loop the chapter, grade yourself honestly at the end, and make a flashcard for anything you couldn't explain.

---

## 7. Smart Rewind — pick up where your *mind* left off

**What it does:** When you resume after a pause, Echo automatically rewinds — a little after a short pause, more after minutes, a lot after hours or days. You configure the levels; Echo applies them silently every time you hit play.

**The science: Interruption & Resumption.** Research on task interruption (Monk, Trafton & Boehm-Davis, 2008) shows that resuming after a break carries a real cost — a "resumption lag" while your brain rebuilds the context it dropped. The longer the interruption, the more context is gone. Re-hearing the last stretch is the cheapest way to rebuild it: it reinstates the narrative context so the next sentence has something to attach to.

This is the feature that makes Echo survive real life. Standard players punish every interruption with confusion ("wait, who's talking?"); Echo absorbs the interruption for you.

- Tune the three tiers (seconds / minutes / hours) to your life. Hopping out of a delivery vehicle every few minutes? Short-pause rewind of ~10 seconds. Overnight gap? A minute or more.
- Don't fight it. If the rewound material feels boringly familiar — perfect. That's confirmation you encoded it the first time, and it costs seconds.

---

## 8. Read Along — the synced EPUB & PDF reader

**What it does:** Add the EPUB or PDF next to your audiobook and Echo aligns text to audio — on-device, using its own speech recognition. The Read tab scrolls with the narration, highlighting the active paragraph. Tap any paragraph to jump the audio there. Search the full text and leap to the moment it's *spoken*. And when the narrator says "as shown in the diagram" — the diagram is right there.

**The science: Dual Coding.** Allan Paivio's dual coding theory holds that information encoded both verbally and visually creates two interconnected memory traces instead of one — and decades of multimedia-learning research backs the practical upshot: synchronized words + visuals beat either alone. Reading along also keeps wandering attention tethered: when your eyes lose the thread, your ears still have it, and vice versa.

Many people — especially many neurodivergent people — simply cannot absorb a book through one channel alone. Echo never asks you to.

- Run **Auto-Align Chapters** once when you add a book; let drift detection and repair do the fussy work. Lock a manual anchor anywhere it matters.
- Listening-first day? Leave the reader closed and trust the bookmarks. Studying? Open the Read tab — especially for diagram-heavy non-fiction.
- Use search as memory rescue: "they said something about cortisol…" → search → tap → you're hearing that exact sentence.
- Dyslexic or just prefer it? Switch the reader to **OpenDyslexic** or **Lexend** — both built in, both chosen from reading-fluency research.

---

## 9. Voice Memo Bookmarks — think out loud, keep the thought

**What it does:** Hold the bookmark button and talk. Your memo is pinned to that exact second of the book — and Echo can play memos back *inline* when playback reaches them, so past-you briefs present-you right on cue. On the road, ask Siri or use the watch; your hands never leave the wheel.

**The science: Self-Explanation & the Production Effect.** Explaining material in your own words — even just to yourself — is one of the most reliable comprehension boosters in the literature (the "self-explanation effect," Chi et al., 1989). Separately, the "production effect" (MacLeod et al., 2010) shows that material you say *out loud* is remembered better than material you merely think. A voice memo does both at once. The recording is almost a bonus — the speaking already did half the work.

- Capture *your reaction*, not a summary: "this contradicts what chapter 2 said" beats "interesting point."
- Say why it matters to *you*: "use this in Thursday's meeting." Future relevance is a powerful retrieval hook.
- Leave inline playback on for review listens. Your own voice interrupting the narrator is exactly the cue-rich, slightly weird moment that sticks.

---

## 10. Pristine Speed Control — faster without the chipmunks

**What it does:** Echo adjusts playback speed with proper pitch correction, so 1.25× sounds like a quicker human, not a cartoon. Speed is remembered per book.

**The science: comprehension has a speed budget.** Studies of time-compressed speech show comprehension holds up well at moderate accelerations, then degrades as speed climbs — and *new, dense* material burns the budget fastest. The skill is matching speed to difficulty: cruise through familiar territory, slow down where ideas are thick.

- Set a comfortable default (1.25× is most people's sweet spot), then adjust *per book* — Echo remembers each one.
- Hit a dense argument? Drop to 1× and loop it rather than plowing through at speed.
- Re-listens of looped chapters can run faster — you're reinforcing, not decoding.

---

## 11. Insights — see yourself learn — 🚧 Coming in 1.0

**What it does:** A dedicated Insights screen built from your actual listening and review history — computed on your device, from your own data, never sent anywhere. Listening time by day, week, month, or year. Streaks and a review-day heatmap. A per-book drill-down with **chapter coverage** ("Chapter 7 — 86% covered, listened 3×"). Your speed trend, your session lengths, your best time of day. For flashcards: reviews per day, a retention curve, grade distribution, and a 30-day due forecast so review debt never ambushes you. If you use Context Memory, a simple list of the places you listen most.

**The science: Self-Monitoring & Feedback.** Learners are famously bad at judging their own learning — re-reading *feels* effective precisely when it isn't. Decades of work on self-regulated learning (Zimmerman, 2002) put accurate self-monitoring at the center of effective studying, and Hattie & Timperley's landmark review (2007) ranks concrete feedback among the most powerful influences on learning. Honest data substitutes for vibes. Goal-setting research (Locke & Latham, 2002) adds the second half: specific, visible progress against a specific target sustains effort far better than "do your best."

- **Check coverage before a re-listen.** The chapter heatmap shows exactly which chapters you've actually heard versus skimmed past — re-listen to the gaps, not the whole book.
- **Use the due forecast to right-size your card-making.** Fifty new cards today is two hundred reviews next month. The forecast makes the trade visible while you can still adjust.
- **Find your golden hours.** The time-of-day chart tells you when you actually listen and retain. Schedule the dense book there.
- **Streaks bend, they don't break.** A missed day is data, not a verdict. The goal is the trend line, not a perfect chain — see the [Focus guide on all-or-nothing thinking](focus-field-guide.md#6-all-or-nothing-thinking--finding-the-gray) for why this matters double for ADHD brains.

> 📸 *Screenshot coming soon — Insights: listening totals, streak, chapter-coverage heatmap, retention curve.*

---

## 12. Second-Brain Export — make it yours forever — 🚧 Coming in 1.0

**What it does:** One tap exports a book's entire study record as a clean, portable Markdown bundle: every bookmark with its timestamp and note, your brain-dump entries, flashcard fronts and backs, chapter headings — plus an assets folder with your voice memos and photos. Drop the folder into **Obsidian**, **Logseq**, or **Notion**, or just keep it as files. No account, no API, no lock-in. (Bookmark-only Markdown export ships today; the full study bundle lands in 1.0.)

**The science: the Generation Effect & trusted storage.** Two principles meet here. First, the *generation effect* (Slamecka & Graf, 1978): material you produce yourself is remembered better than material you receive — and your exported notes are exactly the material you generated. Reorganizing them in your own system is another generation pass, not busywork. Second, offloading only works when the external store is *trusted* (Risko & Gilbert, 2016): a capture system you can't search or might lose teaches your brain to keep white-knuckling everything. Plain files in your own vault are the most trustworthy storage that exists.

- Export when you *finish* a book and spend twenty minutes reorganizing the notes in your own words — that pass is studying, disguised as filing.
- Link book notes to your existing notes ("connects to [[Atomic Habits]]"). Connections are retrieval routes.
- Keep the audio cards in Echo for scheduled review; use the export as the searchable archive. Different tools, different jobs.

---

## 13. Pomodoro Timer — attention is a budget

**What it does:** A focus timer on your wrist, inside the watch remote: set a work interval, get a persistent alarm when it ends, glance at progress without touching your phone.

**The science: attention management.** The Pomodoro Technique (Francesco Cirillo) operationalizes two well-supported ideas: sustained attention degrades over long unbroken stretches, and committing to a *defined, finite* interval lowers the activation energy to start — the hardest part for any brain, and famously so for ADHD brains. Brief rests between intervals also give memory consolidation a quiet moment to work.

- Pair a pomodoro with a chapter: "one 25-minute interval on chapter 6, then I grade myself."
- Use the break for retrieval, not scrolling: thirty seconds of "what did I just hear?" turns a rest into a review.

---

## 14. Sleep Timer — end the day, keep the thread

**What it does:** Fade out and pause after a set time or at chapter's end — and tomorrow, Smart Rewind backs you up over the part you drifted through, automatically.

Sleep is when the hippocampus replays and consolidates the day's learning — but material you heard *while falling asleep* was barely encoded to begin with. The honest combination is exactly what Echo does: stop playback when you fade, then re-cover that ground on resume instead of pretending you heard it.

---

## The Echo Method — putting it together

1. **First pass (listen):** normal or slightly raised speed. When something lands, bookmark it — voice memo if your hands are busy, photo if the moment is distinctive. A passing thought about anything else? Brain-dump it and keep listening. (🚧)
2. **Mark the card-worthy moments:** one tap, no pause. They'll wait in the Card Inbox. (🚧)
3. **Loop what matters:** for dense chapters, loop until you could explain them. One or two chapters a day is a *fast* pace for real learning.
4. **Harvest on your schedule:** at home, process the inboxes — promote marks to flashcards (front as a question, audio attached), promote brain-dump keepers to bookmarks or cards, delete the rest.
5. **Review daily:** when the notification arrives, clear your due cards — phone or watch, five-ish minutes.
6. **Check Insights weekly:** coverage gaps tell you what to re-listen; the due forecast tells you whether to ease up on new cards. (🚧)
7. **Read-along pass (optional, for the big books):** weekend re-listen with the Read tab open, eyes on the diagrams your ears skipped.
8. **Graduate the book:** when you're done, export the study bundle to your second brain and reorganize it in your own words. (🚧)

None of these steps is hard; the entire system is designed to run inside a life full of interruptions — because it was built inside one.

---

## Sources & further reading

- Godden & Baddeley (1975). Context-dependent memory in two natural environments. *British Journal of Psychology.*
- Smith & Vela (2001). Environmental context-dependent memory: A review and meta-analysis. *Psychonomic Bulletin & Review.*
- Tulving & Thomson (1973). Encoding specificity and retrieval processes in episodic memory. *Psychological Review.*
- Ebbinghaus (1885). *Memory: A Contribution to Experimental Psychology.*
- Cepeda et al. (2006). Distributed practice in verbal recall tasks. *Psychological Bulletin.*
- Roediger & Karpicke (2006). Test-enhanced learning. *Psychological Science.*
- Bjork (1994). Memory and metamemory considerations in the training of human beings.
- Paivio (1986). *Mental Representations: A Dual Coding Approach.*
- Chi et al. (1989). Self-explanations. *Cognitive Science.*
- MacLeod et al. (2010). The production effect. *JEP: Learning, Memory, and Cognition.*
- Monk, Trafton & Boehm-Davis (2008). The effect of interruption duration and demand on resuming suspended goals. *JEP: Applied.*
- Maguire et al. (2003). Routes to remembering: the brains behind superior memory. *Nature Neuroscience.*
- Leroy (2009). Why is it so hard to do my work? The challenge of attention residue. *Organizational Behavior and Human Decision Processes.*
- Zeigarnik (1927). Das Behalten erledigter und unerledigter Handlungen. *Psychologische Forschung.*
- Masicampo & Baumeister (2011). Consider it done! Plan making can eliminate the cognitive effects of unfulfilled goals. *Journal of Personality and Social Psychology.*
- Risko & Gilbert (2016). Cognitive offloading. *Trends in Cognitive Sciences.*
- Cowan (2010). The magical mystery four: How is working memory capacity limited, and why? *Current Directions in Psychological Science.*
- Slamecka & Graf (1978). The generation effect: Delineation of a phenomenon. *JEP: Human Learning and Memory.*
- Zimmerman (2002). Becoming a self-regulated learner: An overview. *Theory Into Practice.*
- Hattie & Timperley (2007). The power of feedback. *Review of Educational Research.*
- Locke & Latham (2002). Building a practically useful theory of goal setting and task motivation. *American Psychologist.*
- Lally et al. (2010). How are habits formed: Modelling habit formation in the real world. *European Journal of Social Psychology.*

*Echo is not a medical device and makes no clinical claims — it's a media player built with care around how memory actually works.*
