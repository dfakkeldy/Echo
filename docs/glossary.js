/* Echo web glossary — single source of truth.
   Data + glossary-page renderer + inline popover engine. No dependencies.
   category ∈ "Technical" | "Learning science" | "Formats & domain" */
(function () {
  "use strict";

  var GLOSSARY = [
    // ---- Technical -----------------------------------------------------
    { slug: "whisperkit", term: "WhisperKit", category: "Technical",
      short: "Apple-silicon speech-to-text that runs entirely on your device — no audio is ever uploaded.",
      long: "An on-device speech-recognition engine (OpenAI's Whisper model converted to Apple's CoreML). Echo uses it to 'listen' to a few seconds of narration and match it to the book text, so alignment needs no internet and no cloud service ever hears your audio." },
    { slug: "coreml", term: "CoreML", category: "Technical",
      short: "Apple's framework for running machine-learning models locally on iPhone and Mac hardware.",
      long: "Apple's on-device machine-learning runtime. It lets models like WhisperKit run fast on the phone's Neural Engine instead of on a server — the reason Echo's alignment is private and works offline." },
    { slug: "dtw", term: "TokenDTW / Dynamic Time Warping", category: "Technical",
      short: "An algorithm that lines up two sequences running at different speeds — here, spoken words vs. written words.",
      long: "Dynamic Time Warping finds the best correspondence between two sequences that drift in timing. Echo's TokenDTW matches the words it heard against the words on the page to pin each paragraph to the right moment in the audio, even when the narrator pauses, repeats, or skips." },
    { slug: "vad", term: "VAD (voice-activity detection)", category: "Technical",
      short: "Detecting where speech starts and stops, so audio can be cut at natural silences.",
      long: "Voice-activity detection finds the gaps between speech. Echo uses it to chop narration into clean chunks at silences before transcribing, which makes alignment faster and more accurate." },
    { slug: "levenshtein", term: "Levenshtein distance", category: "Technical",
      short: "A count of the single-character edits needed to turn one word into another — i.e. how similar they are.",
      long: "The number of insertions, deletions, or substitutions needed to change one string into another. Echo uses it to forgive small transcription errors when matching heard words to the book's text." },
    { slug: "jaccard", term: "Jaccard similarity", category: "Technical",
      short: "A 0–1 score for how much two sets of words overlap.",
      long: "A measure of overlap between two sets — shared items divided by total items. Echo compares the words in a heard passage against a paragraph's words to judge whether they're the same passage." },
    { slug: "grdb", term: "GRDB", category: "Technical",
      short: "The Swift library Echo uses to store your data in a local SQLite database on the device.",
      long: "A well-regarded Swift wrapper around SQLite. It's where Echo keeps bookmarks, flashcards, notes, and alignment data — all on your device, no server involved." },
    { slug: "schema-migration", term: "Schema migration", category: "Technical",
      short: "A versioned, automatic upgrade of the local database's structure when the app gains new features.",
      long: "When a new Echo version needs a new column or table, a numbered migration (e.g. Schema_V11) updates your existing database in place on first launch, so an app update never loses your data." },
    { slug: "security-scoped-bookmark", term: "Security-scoped bookmark", category: "Technical",
      short: "A token that lets Echo re-open a file you picked, across restarts, without copying it.",
      long: "An Apple security feature: when you grant Echo access to a file or folder, the app saves a 'security-scoped bookmark' so it can reopen exactly that location later without asking again — while the rest of your disk stays off-limits." },
    { slug: "keychain", term: "Keychain", category: "Technical",
      short: "Apple's encrypted store for small secrets — used here for those file-access tokens.",
      long: "The system's encrypted vault for sensitive data. Echo keeps security-scoped bookmark tokens there rather than in plain settings, so they're protected at rest." },
    { slug: "observable", term: "@Observable", category: "Technical",
      short: "A Swift feature that makes the screen update automatically when the underlying data changes.",
      long: "A modern Swift annotation that makes a data object 'observable': when its values change, any SwiftUI view showing them refreshes automatically. It's the backbone of how Echo's player UI stays in sync with playback." },
    { slug: "dependency-injection", term: "Dependency / closure injection", category: "Technical",
      short: "Building an object by handing it the helpers it needs, instead of letting it create its own.",
      long: "A design practice where a component is given ('injected') its collaborators from outside instead of constructing them internally. Echo's PlayerModel is assembled this way from 20-plus small services, which keeps each piece focused and testable." },
    { slug: "watchconnectivity", term: "WatchConnectivity (WCSession)", category: "Technical",
      short: "Apple's channel for the iPhone and Apple Watch apps to talk to each other.",
      long: "The framework that carries messages between Echo on iPhone and Echo on Apple Watch — play/pause, skip, scrub, bookmarks, and layout changes all flow over a WCSession in both directions." },
    { slug: "app-group", term: "App Group", category: "Technical",
      short: "A shared sandbox that lets the app and its widget read the same data.",
      long: "An Apple mechanism that lets related targets (the main app and its Home/Lock-Screen widget) share a small pocket of storage, so the widget can show the current track and progress." },
    { slug: "accelerate", term: "Accelerate", category: "Technical",
      short: "Apple's library of hand-optimized math, used for fast audio number-crunching.",
      long: "A high-performance Apple framework for vector and signal math. Echo leans on it for the heavy number work in silence detection and audio analysis so the UI never stalls." },

    // ---- Learning science ----------------------------------------------
    { slug: "spaced-repetition", term: "Spaced repetition (SRS)", category: "Learning science",
      short: "Reviewing material at growing intervals so it sticks with the least effort.",
      long: "A study method (and the systems that automate it, 'SRS') that schedules each review just before you'd forget. Echo's flashcards use it so you spend time only on what's about to slip, not what you already know." },
    { slug: "sm2", term: "SM-2 algorithm", category: "Learning science",
      short: "The classic formula that decides when each flashcard is shown next — the one Anki was built on.",
      long: "The scheduling algorithm behind spaced repetition: after each review it adjusts how long until the card returns, based on how easily you recalled it. Echo uses the same SM-2 that Anki popularised." },
    { slug: "context-dependent-memory", term: "Context-dependent memory", category: "Learning science",
      short: "We recall things better in the setting where we learned them; cues from that setting pull the memory back.",
      long: "Your brain encodes the surrounding environment alongside what you're learning, so re-encountering that environment (or even a photo of it) helps retrieve the memory. Echo's photo and place bookmarks turn this into a deliberate study tool." },
    { slug: "testing-effect", term: "The testing effect", category: "Learning science",
      short: "Recalling something from memory strengthens it far more than re-reading it.",
      long: "Also called retrieval practice: the act of pulling an answer out of your head, effortfully, builds memory better than passive review. It's why Echo's flashcards ask you to answer before revealing." },
    { slug: "cognitive-offloading", term: "Cognitive offloading", category: "Learning science",
      short: "Parking a thought somewhere trusted so your mind is free to keep going.",
      long: "Moving information out of your head into an external store (a note, a bookmark) so working memory isn't clogged. Echo's brain-dump and mark-now-card-later flows are built around it." },
    { slug: "dual-coding", term: "Dual coding", category: "Learning science",
      short: "Pairing words with images creates two memory paths to the same idea.",
      long: "The theory that information encoded both verbally and visually is recalled better, because there are two routes back to it. Echo's hybrid text-plus-audio reading and photo bookmarks lean on this." },
    { slug: "retrieval-cue", term: "Retrieval cue", category: "Learning science",
      short: "A trigger — a place, image, or question — that pulls a stored memory back to mind.",
      long: "Anything that helps you access a memory: a photo, a location, the narrator's voice. Echo deliberately attaches cues to what you learn so recall has something to grab." },
    { slug: "interleaving", term: "Interleaving", category: "Learning science",
      short: "Mixing different topics in one session instead of blocking them, which improves retention.",
      long: "Alternating between related topics or problem types rather than drilling one to exhaustion. It feels harder but builds more durable, flexible memory — a 'desirable difficulty.'" },

    // ---- Formats & domain ----------------------------------------------
    { slug: "epub", term: "EPUB", category: "Formats & domain",
      short: "The open ebook format — reflowable text, headings, and images — used as Echo's companion reader.",
      long: "A standard, open ebook file (essentially zipped web pages). Drop one beside your audiobook and Echo's Reader tab shows the text in sync with the narration." },
    { slug: "m4b", term: "M4B", category: "Formats & domain",
      short: "An audiobook file that bundles chapters and cover art into one tidy file.",
      long: "An audio container made for audiobooks: a single file with embedded chapter markers and artwork. Echo reads its chapters instantly and can match those chapter titles to the EPUB without any machine learning." },
    { slug: "opf-spine", term: "OPF spine", category: "Formats & domain",
      short: "The EPUB's list of sections in reading order.",
      long: "Inside an EPUB, the OPF file's 'spine' is the ordered list of content documents — the official reading order. Echo follows it to extract paragraphs in the right sequence." },
    { slug: "xhtml", term: "XHTML", category: "Formats & domain",
      short: "The strict, web-page-like markup that holds an EPUB's actual text.",
      long: "A stricter form of HTML. Each chapter of an EPUB is an XHTML document; Echo parses these to pull out paragraphs, headings, and images for the Reader." },
    { slug: "alignment", term: "Audio–text alignment", category: "Formats & domain",
      short: "The map that ties each paragraph of the book to the exact moment it's spoken.",
      long: "Alignment is what lets Echo scroll the text in time with the narration and jump from a sentence to its audio (and back). Echo can build it automatically on-device, and you can correct it anywhere." },
    { slug: "alignment-anchor", term: "Alignment anchor", category: "Formats & domain",
      short: "A single locked point pairing one paragraph with one timestamp; the map is drawn between anchors.",
      long: "A pinned correspondence between a spot in the text and a moment in the audio. Echo interpolates between anchors to time everything in between, and adds more anchors where it needs precision." },
    { slug: "drift", term: "Alignment drift / repair", category: "Formats & domain",
      short: "When text and audio gradually slip out of sync — and Echo's fix for it.",
      long: "Over a long chapter, small timing errors accumulate so the highlighted text runs ahead of or behind the voice. Echo detects this 'drift' and repairs it by inserting fresh anchors at word-level precision." },
    { slug: "continuous-alignment", term: "Continuous alignment", category: "Formats & domain",
      short: "An optional mode that keeps refining the audio-text map in the background while you listen.",
      long: "When enabled, Echo samples short windows of audio during playback, transcribes them on-device, and drops in correction anchors on the fly — alignment that improves the more you listen." },
    { slug: "chapter-atom", term: "Chapter atom (sub-section)", category: "Formats & domain",
      short: "A piece of a chapter that some audiobooks split out (e.g. 'Chapter 11.A'); Echo recombines them.",
      long: "Some audiobooks (Libation-style rips) break a chapter into lettered parts. Echo's grouping service collapses these 'atoms' back into one logical chapter while keeping the parts as scrubber tick marks for fine navigation." },
    { slug: "pitch-corrected", term: "Pitch-corrected speed", category: "Formats & domain",
      short: "Speeding up audio without the chipmunk effect — faster tempo, same natural voice.",
      long: "Playing audio above 1× normally raises the pitch; pitch correction speeds the tempo while keeping the voice at its natural pitch, so 1.5× still sounds human." }
  ];

  var CATEGORIES = ["Technical", "Learning science", "Formats & domain"];

  function catId(cat) {
    return "cat-" + cat.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
  }

  var bySlug = {};
  GLOSSARY.forEach(function (e) { bySlug[e.slug] = e; });

  // (renderer added in Task 3, engine in Task 4)

  window.__ECHO_GLOSSARY__ = { entries: GLOSSARY, bySlug: bySlug, catId: catId, categories: CATEGORIES };
})();
