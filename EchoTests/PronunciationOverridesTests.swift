// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct PronunciationOverridesTests {

    @Test func rewritesWholeWordOnly() throws {
        let ovr = PronunciationOverrides(entries: [
            "Kubernetes": "kuːbərˈnɛtɪs"
        ])
        let out = ovr.apply(to: "Deploying Kubernetes to production.")
        #expect(out == "Deploying [Kubernetes](/kuːbərˈnɛtɪs/) to production.")
    }

    @Test func doesNotRewriteSubstrings() throws {
        // "use" must not match inside "user" or "reuse".
        let ovr = PronunciationOverrides(entries: ["use": "juːz"])
        let out = ovr.apply(to: "the user reuses tokens")
        #expect(!out.contains("[user]"))
        #expect(!out.contains("[reuses]"))
    }

    @Test func caseInsensitiveMatch() throws {
        let ovr = PronunciationOverrides(entries: ["postgres": "ˈpɒstɡrɛs"])
        let out = ovr.apply(to: "Postgres and POSTGRES both match.")
        #expect(out.contains("[Postgres](/ˈpɒstɡrɛs/)"))
        #expect(out.contains("[POSTGRES](/ˈpɒstɡrɛs/)"))
    }

    @Test func mergesGlobalAndPerBookBookWins() throws {
        let ovr = PronunciationOverrides.merging(
            global: ["docker": "ˈdɒkə"],
            book: ["docker": "ˈdɑkər"])
        #expect(ovr.entries["docker"] == "ˈdɑkər") // book overrides global
    }

    @Test func emptyOverridesAreNoOp() throws {
        let ovr = PronunciationOverrides(entries: [:])
        let original = "Nothing changes here."
        #expect(ovr.apply(to: original) == original)
    }

    @Test func alreadyLinkedTextIsNotDoubleWrapped() throws {
        // If the source already contains a Misaki link, don't re-wrap.
        let ovr = PronunciationOverrides(entries: ["Kokoro": "kˈOkəɹO"])
        let out = ovr.apply(to: "[Kokoro](/kˈOkəɹO/) models")
        #expect(out == "[Kokoro](/kˈOkəɹO/) models") // unchanged
    }

    @Test func reOverrideDoesNotCorruptContractions() throws {
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(
            to: "you're we're they’re and re-rendered all survived.")

        #expect(out.contains("you're"))
        #expect(out.contains("we're"))
        #expect(out.contains("they’re"))
        #expect(!out.contains("[re](/ɹi/)'"))
        #expect(out.contains("[re](/ɹi/)-rendered"))
    }
}
