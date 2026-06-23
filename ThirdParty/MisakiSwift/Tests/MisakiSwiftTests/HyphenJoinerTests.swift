import Testing

@testable import MisakiSwift

/// A plain hyphen joining word parts (a hyphenated compound like
/// "rough-and-ready") must read as a smooth word break, NOT a long em-dash
/// pause. Regression for the narrator treating every hyphen like a period/dash.
@Suite struct HyphenJoinerTests {
    private let g2p = EnglishG2P(british: false)

    @Test func hyphenIsNotAnEmDashPause() {
        // The em-dash phoneme "—" (a hard pause) must not appear for a hyphen.
        for compound in ["rough-and-ready", "save-as", "home-screen", "open-source", "well-being"] {
            let (ph, _) = g2p.phonemize(text: compound)
            #expect(
                !ph.contains("—"), "hyphen in \"\(compound)\" rendered as an em-dash pause: \(ph)")
        }
    }

    @Test func hyphenJoinsPartsWithAWordBreak() {
        // "rough-and-ready" → the three parts separated by spaces (word breaks),
        // so it reads "rough and ready" rather than one smushed token.
        let (ph, _) = g2p.phonemize(text: "rough-and-ready")
        #expect(ph.contains(" "))
        #expect(!ph.contains("—"))
    }

    @Test func realEmDashStillPauses() {
        // A genuine em-dash between words is a deliberate pause — keep it.
        let (ph, _) = g2p.phonemize(text: "stop—now")
        #expect(ph.contains("—"))
    }
}
