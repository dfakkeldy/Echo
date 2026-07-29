// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct UniversalPronunciationResolverTests {
    private let semanticPackVersion =
        "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    private let vocabularyVersion =
        "sha256:1111111111111111111111111111111111111111111111111111111111111111"

    private func pack(
        automaticEntries: [String: (candidateID: String, ipa: String)] = [:],
        ambiguousWords: Set<String> = [],
        packVersion: String? = nil,
        kokoroVocabularyVersion: String? = nil,
        generationTimestamp: String = "2026-07-29T00:00:00Z"
    ) -> EnglishPronunciationPack {
        EnglishPronunciationPack.emptyForTesting(
            packVersion: packVersion ?? semanticPackVersion,
            kokoroVocabularyVersion: kokoroVocabularyVersion ?? vocabularyVersion,
            generationTimestamp: generationTimestamp,
            automaticEntries: automaticEntries,
            ambiguousWords: ambiguousWords)
    }

    @Test func exactSupplementalCandidateCreatesAuditableLink() throws {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])

        let result = UniversalPronunciationResolver.rewrite(
            to: "A foobar appeared.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == "A [foobar](/fˈubɑɹ/) appeared.")
        let seed = try #require(result.decisionSeeds.first)
        #expect(result.decisionSeeds.count == 1)
        #expect(seed.source == .supplementalLexicon)
        #expect(seed.candidateID == "cmudict.foobar.fixture")
        #expect(seed.candidatePackVersion == supplementalPack.packVersion)
        #expect(seed.derivationBase == nil)
        #expect(seed.derivationRuleID == nil)
    }

    @Test func exactRewritePreservesCasePunctuationAndExistingLinks() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])

        let result = UniversalPronunciationResolver.rewrite(
            to: "Foobar, [foobar](/custom/) and foobar!",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            result.text
                == "[Foobar](/fˈubɑɹ/), [foobar](/custom/) and [foobar](/fˈubɑɹ/)!")
        #expect(result.decisionSeeds.map(\.sourceWord) == ["Foobar", "foobar"])
        #expect(result.decisionSeeds.map(\.wordStart) == [0, 3])
    }

    @Test func exactSupplementalCandidatesUseWholeHyphenAndApostropheTokens() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "aujourd'hui": ("cmudict.aujourd'hui.fixture", "oʒuɹdɥˈi"),
        ])

        let result = UniversalPronunciationResolver.rewrite(
            to: "An ad-hoc aujourd’hui and aujourd'hui test.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            result.text
                == "An [ad-hoc](/ˈædhˈɑk/) [aujourd’hui](/oʒuɹdɥˈi/) and [aujourd'hui](/oʒuɹdɥˈi/) test.")
        #expect(
            result.decisionSeeds.map(\.normalizedWord)
                == ["ad-hoc", "aujourd'hui", "aujourd'hui"])
        #expect(
            result.decisionSeeds.map(\.sourceWord)
                == ["ad-hoc", "aujourd’hui", "aujourd'hui"])
    }

    @Test func ineligibleConnectedTokensNeverRewriteEligibleFragments() {
        let supplementalPack = pack(automaticEntries: [
            "ad": ("cmudict.ad.fixture", "ˈæd"),
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "hoc": ("cmudict.hoc.fixture", "hˈɑk"),
            "aujourd": ("cmudict.aujourd.fixture", "oʒˈuɹ"),
            "hui": ("cmudict.hui.fixture", "hˈui"),
        ])

        let unsupportedConnectedTokens = [
            "ad_hoc",
            "ad\u{203F}hoc",
            "ad2hoc",
            "ad\u{00AD}hoc",
            "ad\u{200D}hoc",
            "ad\u{2010}hoc",
            "ad‑hoc",
            "ad\u{FF0D}hoc",
            "ad·hoc",
            "ad\u{0301}-hoc",
            "ad_-hoc",
            "ad''hoc",
            "aujourd''hui",
            "_ad-hoc_",
            "-ad-hoc-",
            "\u{200D}ad-hoc",
            "ad-hoc\u{200D}",
            "ad👩‍💻hoc",
            "aujourd‘hui",
            "*ad-hoc*",
            "**ad-hoc**",
        ]
        for sourceToken in unsupportedConnectedTokens {
            let source = "An \(sourceToken) example."
            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })

            #expect(result.text == source)
            #expect(result.decisionSeeds.isEmpty)
        }
    }

    @Test func supportedOrdinaryAndQuotedWordsStillResolve() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "aujourd'hui": ("cmudict.aujourd'hui.fixture", "oʒuɹdɥˈi"),
        ])
        let result = UniversalPronunciationResolver.rewrite(
            to: "An ad-hoc note said, “aujourd’hui.”",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            result.text
                == "An [ad-hoc](/ˈædhˈɑk/) note said, “[aujourd’hui](/oʒuɹdɥˈi/).”")
        #expect(result.decisionSeeds.map(\.normalizedWord) == ["ad-hoc", "aujourd'hui"])
        #expect(result.decisionSeeds.map(\.sourceWord) == ["ad-hoc", "aujourd’hui"])
    }

    @Test func balancedSingleQuotedWordsResolveWithoutAbsorbingTheirQuotes() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])
        let result = UniversalPronunciationResolver.rewrite(
            to: "An 'ad-hoc' and ‘ad-hoc’ example.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            result.text
                == "An '[ad-hoc](/ˈædhˈɑk/)' and ‘[ad-hoc](/ˈædhˈɑk/)’ example.")
        #expect(result.decisionSeeds.map(\.wordStart) == [1, 3])
        #expect(result.decisionSeeds.map(\.wordEnd) == [1, 3])
        #expect(result.decisionSeeds.map(\.sourceWord) == ["ad-hoc", "ad-hoc"])
        #expect(result.decisionSeeds.map(\.normalizedWord) == ["ad-hoc", "ad-hoc"])
        #expect(result.decisionSeeds.map(\.selectedIPA) == ["ˈædhˈɑk", "ˈædhˈɑk"])
        #expect(
            result.decisionSeeds.map(\.candidateID)
                == ["cmudict.ad-hoc.fixture", "cmudict.ad-hoc.fixture"])
        #expect(result.decisionSeeds.allSatisfy { $0.source == .supplementalLexicon })
    }

    @Test func punctuationInsideBalancedSingleQuotesRemainsOutsideTheRewrite() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])
        let result = UniversalPronunciationResolver.rewrite(
            to: "An ('ad-hoc,') and [‘ad-hoc!’] example.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            result.text
                == "An ('[ad-hoc](/ˈædhˈɑk/),') and [‘[ad-hoc](/ˈædhˈɑk/)!’] example.")
        #expect(result.decisionSeeds.map(\.wordStart) == [1, 3])
        #expect(result.decisionSeeds.map(\.wordEnd) == [1, 3])
        #expect(result.decisionSeeds.map(\.sourceWord) == ["ad-hoc", "ad-hoc"])
        #expect(result.decisionSeeds.map(\.normalizedWord) == ["ad-hoc", "ad-hoc"])
        #expect(
            result.decisionSeeds.map(\.candidateID)
                == ["cmudict.ad-hoc.fixture", "cmudict.ad-hoc.fixture"])
        #expect(
            result.decisionSeeds.allSatisfy {
                $0.source == .supplementalLexicon
                    && $0.ruleID == "supplemental-lexicon.exact.v1"
            })
    }

    @Test func balancedQuotedContractionsRemainIneligible() {
        let supplementalPack = pack(automaticEntries: [
            "can't": ("cmudict.cant.fixture", "kˈænt"),
            "won't": ("cmudict.wont.fixture", "wˈoʊnt"),
            "isn't": ("cmudict.isnt.fixture", "ˈɪzənt"),
            "we're": ("cmudict.were.fixture", "wˈiɹ"),
            "they've": ("cmudict.theyve.fixture", "ðˈeɪv"),
            "he'd": ("cmudict.hed.fixture", "hˈid"),
            "you'll": ("cmudict.youll.fixture", "jˈul"),
            "i'm": ("cmudict.im.fixture", "ˈaɪm"),
            "it's": ("cmudict.its.fixture", "ˈɪts"),
            "aujourd'hui": ("cmudict.aujourd'hui.fixture", "oʒuɹdɥˈi"),
        ])
        let source =
            "He said 'can't', ‘can’t’, 'won't', 'isn't', 'we're', 'they've', 'he'd', 'you'll', 'i'm', and 'it's', then 'aujourd'hui'."
        let result = UniversalPronunciationResolver.rewrite(
            to: source,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            result.text
                == "He said 'can't', ‘can’t’, 'won't', 'isn't', 'we're', 'they've', 'he'd', 'you'll', 'i'm', and 'it's', then '[aujourd'hui](/oʒuɹdɥˈi/)'.")
        #expect(result.decisionSeeds.map(\.sourceWord) == ["aujourd'hui"])
        #expect(result.decisionSeeds.map(\.normalizedWord) == ["aujourd'hui"])
    }

    @Test func malformedAndLexicalApostrophesRemainIneligible() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "today": ("cmudict.today.fixture", "tədˈeɪ"),
            "dogs": ("cmudict.dogs.fixture", "dˈɑɡz"),
        ])
        let sources = [
            "It is today's example.",
            "The dogs' example.",
            "An 'ad-hoc example.",
            "An ad-hoc’ example.",
            "An ‘’ad-hoc’’ example.",
            "An ‘ad-hoc' example.",
            "An aujourd‘hui example.",
        ]

        for source in sources {
            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(result.text == source)
            #expect(result.decisionSeeds.isEmpty)
        }
    }

    @Test func ordinaryBoundaryPunctuationAndExistingLinksRemainSeparate() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])
        let result = UniversalPronunciationResolver.rewrite(
            to: "“foobar,” (foobar); foobar! [foobar](/custom/)",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            result.text
                == "“[foobar](/fˈubɑɹ/),” ([foobar](/fˈubɑɹ/)); [foobar](/fˈubɑɹ/)! [foobar](/custom/)")
        #expect(result.decisionSeeds.map(\.sourceWord) == ["foobar", "foobar", "foobar"])
        #expect(result.decisionSeeds.map(\.wordStart) == [0, 1, 2])
    }

    @Test func genericMarkdownLinksRemainByteForByteProtected() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "docs": ("cmudict.docs.fixture", "dˈɑks"),
            "example": ("cmudict.example.fixture", "ɪɡzˈæmpəl"),
            "dictionary": ("cmudict.dictionary.fixture", "dˈɪkʃənˌɛɹi"),
        ])
        let source =
            "Read [ad-hoc](https://docs.example.com/dictionary/ad-hoc(a(b)c)) now."

        let result = UniversalPronunciationResolver.rewrite(
            to: source,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == source)
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func nestedAndEscapedMarkdownInlineLabelsRemainProtected() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "reference": ("cmudict.reference.fixture", "ɹˈɛfɚəns"),
        ])
        let sources = [
            #"Read [ad-hoc [reference]](https://example.com/a(b)c) now."#,
            #"Read [ad-hoc \[reference\]](https://example.com/a(b)c) now."#,
        ]

        for source in sources {
            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(result.text == source)
            #expect(result.decisionSeeds.isEmpty)
        }
    }

    @Test func inlineTitlesAndMultilineReferenceTitlesRemainProtected() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "guide": ("cmudict.guide.fixture", "ɡˈaɪd"),
        ])
        let source = #"""
            [multiline]: https://example.com
              "ad-hoc ("

            [guide](https://example.com "ad-hoc (")
            [guide](https://example.com 'ad-hoc (')
            [guide](https://example.com (ad-hoc\)))
            [guide](<https://example.com/a(b)c> "ad-hoc")
            [guide](https://example.com "ad-hoc \"quoted\"")
            See [multiline].
            """#

        let result = UniversalPronunciationResolver.rewrite(
            to: source,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == source)
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func malformedInlineTitlesFailClosedWithinTheirSourceLine() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])
        let malformedSources = [
            #"[guide](https://example.com "candidate ad-hoc"#,
            #"[guide](https://example.com 'candidate ad-hoc"#,
            #"[guide](https://example.com (candidate ad-hoc"#,
        ]

        for source in malformedSources {
            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })

            #expect(result.text == source)
            #expect(result.decisionSeeds.isEmpty)
        }

        let boundedSource =
            #"[guide](https://example.com "candidate ad-hoc"#
            + "\nOutside ad-hoc."
        let boundedResult = UniversalPronunciationResolver.rewrite(
            to: boundedSource,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })
        #expect(
            boundedResult.text
                == #"[guide](https://example.com "candidate ad-hoc"#
                + "\nOutside [ad-hoc](/ˈædhˈɑk/).")
        #expect(boundedResult.decisionSeeds.map(\.sourceWord) == ["ad-hoc"])
    }

    @Test func malformedNextLineReferenceTitlesFailClosedWithinTheTitleLine() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])

        for opening in ["\"", "'", "("] {
            let source =
                "[guide]: https://example.com\n"
                + "  \(opening)candidate ad-hoc"
            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })

            #expect(result.text == source)
            #expect(result.decisionSeeds.isEmpty)
        }
    }

    @Test func crlfUnicodeMalformedRecoveryAndValidReferenceTitlesPreserveBoundaries() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])
        let malformed =
            #"[guide](https://example.com "👩‍💻 candidate ad-hoc"#
            + "\r\nOutside 'ad-hoc,' and don't."
        let malformedResult = UniversalPronunciationResolver.rewrite(
            to: malformed,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            malformedResult.text
                == #"[guide](https://example.com "👩‍💻 candidate ad-hoc"#
                + "\r\nOutside '[ad-hoc](/ˈædhˈɑk/),' and don't.")
        #expect(malformedResult.decisionSeeds.map(\.sourceWord) == ["ad-hoc"])

        let validReference =
            #"[guide]: https://example.com"#
            + "\r\n"
            + #"  "👩‍💻 ad-hoc \"quoted\"""#
            + "\r\nSee [guide]."
        let validResult = UniversalPronunciationResolver.rewrite(
            to: validReference,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })
        #expect(validResult.text == validReference)
        #expect(validResult.decisionSeeds.isEmpty)
    }

    @Test func referenceDefinitionsAndUsesRemainProtectedWhenDefinitionAware() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "display": ("cmudict.display.fixture", "dɪsplˈeɪ"),
        ])
        let source = """
            [ad-hoc]: https://example.com/dictionary/ad-hoc

            See [ad-hoc][], [display][ad-hoc], and [ad-hoc].
            """

        let result = UniversalPronunciationResolver.rewrite(
            to: source,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == source)
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func editorialBracketsResolveButUnrecognizedConnectedReferencesFailClosed() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])
        let editorial = UniversalPronunciationResolver.rewrite(
            to: "An [ad-hoc] note.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })
        #expect(editorial.text == "An [[ad-hoc](/ˈædhˈɑk/)] note.")
        #expect(editorial.decisionSeeds.map(\.wordStart) == [1])
        #expect(editorial.decisionSeeds.map(\.sourceWord) == ["ad-hoc"])

        for source in [
            "An [ad-hoc][] note.",
            "An [ad-hoc][missing] note.",
            "An [ad-hoc label][missing] note.",
        ] {
            let unresolvedReference = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(unresolvedReference.text == source)
            #expect(unresolvedReference.decisionSeeds.isEmpty)
        }
    }

    @Test func editorialBracketTrailingPunctuationStaysOutsideExactRewrite() throws {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])
        let cases = [
            ("An [ad-hoc], note.", "An [[ad-hoc](/ˈædhˈɑk/)], note."),
            ("An [ad-hoc].", "An [[ad-hoc](/ˈædhˈɑk/)]."),
            ("An [ad-hoc]! Really.", "An [[ad-hoc](/ˈædhˈɑk/)]! Really."),
        ]

        for (source, expected) in cases {
            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "editorial-block",
                pack: supplementalPack,
                basePronunciation: { _ in nil })

            #expect(result.text == expected)
            let seed = try #require(result.decisionSeeds.first)
            #expect(result.decisionSeeds.count == 1)
            #expect(seed.blockID == "editorial-block")
            #expect(seed.wordStart == 1)
            #expect(seed.wordEnd == 1)
            #expect(seed.sourceWord == "ad-hoc")
            #expect(seed.normalizedWord == "ad-hoc")
            #expect(seed.selectedIPA == "ˈædhˈɑk")
            #expect(seed.source == .supplementalLexicon)
            #expect(seed.ruleID == "supplemental-lexicon.exact.v1")
            #expect(seed.candidateID == "cmudict.ad-hoc.fixture")
            #expect(seed.candidatePackVersion == supplementalPack.packVersion)
            #expect(seed.derivationBase == nil)
            #expect(seed.derivationRuleID == nil)
        }
    }

    @Test func editorialBracketsDoNotAdmitMarkdownOrConnectedSuffixes() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])

        for source in [
            "An [ad-hoc][missing] note.",
            "An [ad-hoc](broken",
            "An [ad-hoc]_suffix note.",
            "An [ad-hoc]suffix note.",
        ] {
            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(result.text == source)
            #expect(result.decisionSeeds.isEmpty)
        }
    }

    @Test func repeatedMultiwordEditorialBracketsUseBoundedParserInspectionWork() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])
        let source = String(repeating: "[ad-hoc editorial] ", count: 1_000)
        var parserInspectionCount = 0
        var auditSnapshotConstructionCount = 0

        let result = UniversalPronunciationResolver.rewrite(
            to: source,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil },
            parserInspectionCount: &parserInspectionCount,
            auditSnapshotConstructionCount: &auditSnapshotConstructionCount)

        #expect(result.decisionSeeds.count == 1_000)
        #expect(parserInspectionCount <= source.count * 20)
        #expect(auditSnapshotConstructionCount == 1)
    }

    @Test func interleavedProtectedIntervalsUseSourceLinearResolverWork() throws {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])

        for repetitionCount in [1_000, 2_000, 4_000] {
            let source = String(
                repeating: "[guide](https://example.com/ad-hoc) ad-hoc ",
                count: repetitionCount)
            var operationCounts = UniversalPronunciationResolver.OperationCounts()

            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil },
                operationCounts: &operationCounts)

            #expect(result.decisionSeeds.count == repetitionCount)
            #expect(result.decisionSeeds.first?.wordStart == 1)
            #expect(result.decisionSeeds.last?.wordStart == (repetitionCount * 2) - 1)
            #expect(result.decisionSeeds.allSatisfy { $0.sourceWord == "ad-hoc" })
            #expect(operationCounts.parserInspections <= source.count * 20)
            try #require(operationCounts.protectedIntervalOperations <= source.count * 4)
            #expect(operationCounts.properNameInspections <= source.count * 4)
            #expect(operationCounts.sourceTraversalOperations <= source.count * 28)
            #expect(operationCounts.auditSnapshotConstructions == 1)
        }
    }

    @Test func capitalizedCandidatesUseSourceLinearProperNameWork() throws {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])

        for repetitionCount in [1_000, 2_000, 4_000] {
            let source = "A " + String(repeating: "Foobar ", count: repetitionCount)
            var operationCounts = UniversalPronunciationResolver.OperationCounts()

            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil },
                operationCounts: &operationCounts)

            #expect(result.text == source)
            #expect(result.decisionSeeds.isEmpty)
            #expect(operationCounts.parserInspections <= source.count * 20)
            #expect(operationCounts.protectedIntervalOperations <= source.count * 4)
            try #require(operationCounts.properNameInspections <= source.count * 4)
            #expect(operationCounts.sourceTraversalOperations <= source.count * 28)
            #expect(operationCounts.auditSnapshotConstructions == 1)
        }
    }

    @Test func malformedSquareBracketEnvelopesFailClosed() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk")
        ])

        for source in [
            "An [ad-hoc note.",
            "An ad-hoc] note.",
            "An [[ad-hoc note.",
            "An [ad-hoc[ note.",
        ] {
            let result = UniversalPronunciationResolver.rewrite(
                to: source,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(result.text == source)
            #expect(result.decisionSeeds.isEmpty)
        }
    }

    @Test func plainURLHostsPathsAndDictionaryKeysRemainProtected() {
        let supplementalPack = pack(automaticEntries: [
            "ad-hoc": ("cmudict.ad-hoc.fixture", "ˈædhˈɑk"),
            "docs": ("cmudict.docs.fixture", "dˈɑks"),
            "example": ("cmudict.example.fixture", "ɪɡzˈæmpəl"),
            "dictionary": ("cmudict.dictionary.fixture", "dˈɪkʃənˌɛɹi"),
            "entries": ("cmudict.entries.fixture", "ˈɛntɹiz"),
            "key": ("cmudict.key.fixture", "kˈi"),
        ])
        let source =
            "Visit https://docs.example.com/dictionary/ad-hoc(a(b)c) "
            + "and docs.example.com/entries/ad-hoc[key]."

        let result = UniversalPronunciationResolver.rewrite(
            to: source,
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == source)
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func bundledAutomaticHyphenCandidateIsReachableAsOneExactToken() async throws {
        let bundledPack = await EnglishPronunciationPack.bundledOrEmpty()
        let candidate = try #require(bundledPack.automaticCandidate(for: "ad-hoc"))

        let result = UniversalPronunciationResolver.rewrite(
            to: "An ad-hoc test.",
            blockID: "b1",
            pack: bundledPack,
            basePronunciation: { _ in nil })

        #expect(result.text == "An [ad-hoc](/\(candidate.ipa)/) test.")
        #expect(result.decisionSeeds.map(\.candidateID) == [candidate.candidateID])
        #expect(result.decisionSeeds.map(\.normalizedWord) == ["ad-hoc"])
    }

    @Test func contextualFamiliesAmbiguousCandidatesAndProperNamesAbstain() {
        let supplementalPack = pack(
            automaticEntries: [
                "content": ("cmudict.content.fixture", "kˈɑntɛnt"),
                "live": ("cmudict.live.fixture", "lˈɪv"),
                "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ"),
            ],
            ambiguousWords: ["ambiguous"])

        let result = UniversalPronunciationResolver.rewrite(
            to: "The content is live. Meet Foobar and FOOBAR. An ambiguous case.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == "The content is live. Meet Foobar and FOOBAR. An ambiguous case.")
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func apostrophePossessivesAbstain() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ"),
            "teachers": ("cmudict.teachers.fixture", "tˈitʃɚz"),
        ])

        let result = UniversalPronunciationResolver.rewrite(
            to: "The foobar's result, teachers' guide, and teachers’ lounge.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == "The foobar's result, teachers' guide, and teachers’ lounge.")
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func sentenceStartPolicyDistinguishesTrueStartsFromClausePunctuation() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])

        let rewrittenCases = [
            "Foobar begins.",
            "“Foobar begins.”",
            "[Foobar begins.]",
            "Earlier. Foobar begins.",
            "Earlier? “Foobar begins.”",
            "Earlier! (Foobar begins.)",
            "Earlier… [Foobar begins.]",
            "Earlier\nFoobar begins.",
        ]
        for text in rewrittenCases {
            let result = UniversalPronunciationResolver.rewrite(
                to: text,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(result.decisionSeeds.map(\.normalizedWord) == ["foobar"])
        }

        for text in ["A note; Foobar arrived.", "A note: Foobar arrived."] {
            let result = UniversalPronunciationResolver.rewrite(
                to: text,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(result.text == text)
            #expect(result.decisionSeeds.isEmpty)
        }
    }

    @Test func abbreviationsAndInitialsDoNotProveSentenceStart() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])
        let ambiguousPeriodCases = [
            "Dr. Foobar arrived.",
            "Mr. Foobar arrived.",
            "Mrs. Foobar arrived.",
            "Ms. Foobar arrived.",
            "Prof. Foobar arrived.",
            "No. Foobar arrived.",
            "Fr. Foobar arrived.",
            "Maj. Foobar arrived.",
            "Adm. Foobar arrived.",
            "Mx. Foobar arrived.",
            "Msgr. Foobar arrived.",
            "Cpl. Foobar arrived.",
            "Pvt. Foobar arrived.",
            "Brig. Foobar arrived.",
            "Supt. Foobar arrived.",
            "Det. Foobar arrived.",
            "Messrs. Foobar arrived.",
            "Mlle. Foobar arrived.",
            "Pfc. Foobar arrived.",
            "Esq. Foobar arrived.",
            "Univ. Foobar arrived.",
            "Calif. Foobar arrived.",
            "Art. Foobar arrived.",
            "Mon. Foobar arrived.",
            "Tue. Foobar arrived.",
            "Wed. Foobar arrived.",
            "Thu. Foobar arrived.",
            "Fri. Foobar arrived.",
            "Sat. Foobar arrived.",
            "Sun. Foobar arrived.",
            "Mt. Foobar arrived.",
            "Ens. Foobar arrived.",
            "Atty. Foobar arrived.",
            "Assoc. Foobar arrived.",
            "Exec. Foobar arrived.",
            "Ave. Foobar arrived.",
            "Blvd. Foobar arrived.",
            "Sept. Foobar arrived.",
            "A. Foobar arrived.",
            "U.S. Foobar arrived.",
            "e.g. Foobar arrived.",
            "Version 3.14 Foobar arrived.",
            // Held-out short forms exercise the general v5 rule rather than
            // duplicating individually catalogued implementation entries.
            "Mme. Foobar arrived.",
            "Cmd. Foobar arrived.",
            "Lic. Foobar arrived.",
            "Lab. Foobar arrived.",
            "Ont. Foobar arrived.",
            "Ref. Foobar arrived.",
        ]
        for text in ambiguousPeriodCases {
            let result = UniversalPronunciationResolver.rewrite(
                to: text,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(result.text == text)
            #expect(result.decisionSeeds.isEmpty)
        }

        let trueBoundary = UniversalPronunciationResolver.rewrite(
            to: "Done. Foobar arrived.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })
        #expect(trueBoundary.text == "Done. [Foobar](/fˈubɑɹ/) arrived.")
        #expect(trueBoundary.decisionSeeds.map(\.normalizedWord) == ["foobar"])
    }

    @Test func v6LongerAbbreviationCategoriesDoNotProveSentenceStart() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])
        let requiredCases = [
            "SSgt. Foobar arrived.",
            "Assn. Foobar arrived.",
            "Mass. Foobar arrived.",
            "Chap. Foobar arrived.",
            "Thurs. Foobar arrived.",
        ]
        // Independently selected representatives exercise each named category
        // beyond the five omissions that triggered the v6 review.
        let heldOutCategoryCases = [
            "GySgt. Foobar arrived.",
            "Intl. Foobar arrived.",
            "Penn. Foobar arrived.",
            "Append. Foobar arrived.",
            "Weds. Foobar arrived.",
        ]

        for text in requiredCases + heldOutCategoryCases {
            let result = UniversalPronunciationResolver.rewrite(
                to: text,
                blockID: "b1",
                pack: supplementalPack,
                basePronunciation: { _ in nil })
            #expect(result.text == text)
            #expect(result.decisionSeeds.isEmpty)
        }

        let trueBoundary = UniversalPronunciationResolver.rewrite(
            to: "Done. Foobar arrived.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })
        #expect(trueBoundary.text == "Done. [Foobar](/fˈubɑɹ/) arrived.")
        #expect(trueBoundary.decisionSeeds.map(\.normalizedWord) == ["foobar"])
    }

    @Test func ordinaryWordsPerformNoMorphologyG2PLookups() {
        var calls: [String] = []
        let result = UniversalPronunciationResolver.rewrite(
            to: "The widget uses unknown prose.",
            blockID: "b1",
            pack: pack(),
            basePronunciation: { word in
                calls.append(word)
                return nil
            })

        #expect(result.text == "The widget uses unknown prose.")
        #expect(result.decisionSeeds.isEmpty)
        #expect(calls.isEmpty)
    }

    @Test func eligibleMorphologyPerformsOnlyBoundedWholeAndBaseLookups() {
        var calls: [String] = []
        let result = UniversalPronunciationResolver.rewrite(
            to: "A startable digestible result.",
            blockID: "b1",
            pack: pack(),
            basePronunciation: { word in
                calls.append(word)
                return ["start": "stˈɑɹt", "digest": "daIdʒˈɛst"][word]
            })

        #expect(
            calls
                == ["startable", "start", "starte", "digestible", "digest"])
        #expect(result.decisionSeeds.map(\.normalizedWord) == ["startable", "digestible"])
    }

    @Test func knownEligibleWholeWordStopsBeforeBaseLookups() {
        var calls: [String] = []
        let result = UniversalPronunciationResolver.rewrite(
            to: "A startable result.",
            blockID: "b1",
            pack: pack(),
            basePronunciation: { word in
                calls.append(word)
                return word == "startable" ? "stˈɑɹtəbəl" : nil
            })

        #expect(result.text == "A startable result.")
        #expect(result.decisionSeeds.isEmpty)
        #expect(calls == ["startable"])
    }

    @Test func morphologySupportsExactSilentEAndIbleBases() {
        let known: [String: String] = [
            "start": "stˈɑɹt",
            "reuse": "ɹiːjˈuːz",
            "digest": "daIdʒˈɛst",
        ]
        let result = UniversalPronunciationResolver.rewrite(
            to: "Startable, reusable, digestible.",
            blockID: "b1",
            pack: pack(),
            basePronunciation: { known[$0] })

        #expect(
            result.text
                == "[Startable](/stˈɑɹtəbəl/), [reusable](/ɹiːjˈuːzəbəl/), [digestible](/daIdʒˈɛstəbəl/).")
        #expect(
            result.decisionSeeds.map(\.derivationRuleID)
                == [
                    "morphology.able.exact-base.v1",
                    "morphology.able.silent-e.v1",
                    "morphology.ible.exact-base.v1",
                ])
        #expect(result.decisionSeeds.map(\.derivationBase) == ["start", "reuse", "digest"])
        #expect(result.decisionSeeds.allSatisfy { $0.source == .derivedMorphology })
        #expect(result.decisionSeeds.allSatisfy { $0.candidateID?.isEmpty == false })
        #expect(result.decisionSeeds.allSatisfy { $0.candidatePackVersion?.isEmpty == false })
    }

    @Test func morphologyRequiresExactlyOneValidatedBase() {
        let result = UniversalPronunciationResolver.rewrite(
            to: "The reusable widget.",
            blockID: "b1",
            pack: pack(),
            basePronunciation: { word in
                ["reus": "ɹˈus", "reuse": "ɹiːjˈuːz"][word]
            })

        #expect(result.text == "The reusable widget.")
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func morphologyRejectsNoBaseExceptionsWholeWordsContextAndProperNames() {
        let supplementalPack = pack(automaticEntries: [
            "available": ("cmudict.available.fixture", "əvˈeIləbəl")
        ])
        let known: [String: String] = [
            "comfort": "kˈʌmfɚt",
            "respons": "ɹɪspˈɑns",
            "read": "ɹˈid",
            "start": "stˈɑɹt",
            "available": "əvˈeIləbəl",
        ]

        let result = UniversalPronunciationResolver.rewrite(
            to: "Comfortable responsible readable unavailable available Meet Startable.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { known[$0] })

        #expect(
            result.text
                == "Comfortable responsible readable unavailable [available](/əvˈeIləbəl/) Meet Startable.")
        #expect(result.decisionSeeds.map(\.normalizedWord) == ["available"])
        #expect(result.decisionSeeds.first?.source == .supplementalLexicon)
    }

    @Test func knownWholeWordOrAnySupplementalCandidateBlocksMorphology() {
        let supplementalPack = pack(ambiguousWords: ["testable"])

        let knownWholeWord = UniversalPronunciationResolver.rewrite(
            to: "A startable testable result.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { word in
                [
                    "startable": "stˈɑɹtəbəl",
                    "start": "stˈɑɹt",
                    "test": "tˈɛst",
                ][word]
            })

        #expect(knownWholeWord.text == "A startable testable result.")
        #expect(knownWholeWord.decisionSeeds.isEmpty)
    }

    @Test func morphologyIdentityAndCandidateIDMatchFixedVectors() {
        let fixturePack = pack()
        let policyVersion =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: fixturePack)
        let candidateID = UniversalPronunciationResolver.derivedCandidateID(
            normalizedWord: "startable",
            derivationBase: "start",
            derivationRuleID: "morphology.able.exact-base.v1",
            baseIPA: "stˈɑɹt",
            derivedIPA: "stˈɑɹtəbəl",
            candidatePackVersion: policyVersion)

        #expect(
            policyVersion
                == "morphology-v1:sha256:2580d437001e2d89c46736ba822b130de246f086b0e343af90665fdc1c163280")
        #expect(candidateID == "morphology.startable.bba3cbb67e4e")
        #expect(
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: fixturePack)
                == policyVersion)
        #expect(
            UniversalPronunciationResolver.derivedCandidateID(
                normalizedWord: "startable",
                derivationBase: "start",
                derivationRuleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: policyVersion)
                == candidateID)
    }

    @Test func everyMorphologySemanticInputChangesApplicableIdentity() {
        let fixturePack = pack()
        let baseline =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: fixturePack)
        let changedRule = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: fixturePack,
            ruleIDs: [
                "morphology.able.exact-base.v2",
                "morphology.able.silent-e.v1",
                "morphology.ible.exact-base.v1",
            ])
        let changedException = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: fixturePack,
            exceptionWords: UniversalPronunciationResolver.exceptionWords.union(["changeable"]))
        let changedBasePolicy = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: fixturePack,
            baseEvidencePolicyVersion: "kokoro-nonfallback-rating4-v2")
        let changedProperNamePolicy =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(
                for: fixturePack,
                properNamePolicyVersion: "proper-name-risk-v5")
        let changedPack = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: pack(packVersion: "sha256:" + String(repeating: "2", count: 64)))
        let changedVocabulary = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: pack(kokoroVocabularyVersion: "sha256:" + String(repeating: "3", count: 64)))

        #expect(
            Set([
                baseline, changedRule, changedException, changedBasePolicy,
                changedProperNamePolicy, changedPack, changedVocabulary,
            ]).count == 7)

        let candidateInputs = [
            ("startable", "start", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             baseline),
            ("testable", "start", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             baseline),
            ("startable", "test", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             baseline),
            ("startable", "start", "morphology.able.silent-e.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             baseline),
            ("startable", "start", "morphology.able.exact-base.v1", "stˈɑɹd", "stˈɑɹtəbəl",
             baseline),
            ("startable", "start", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtIbəl",
             baseline),
            ("startable", "start", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             changedPack),
        ]
        let candidateIDs = candidateInputs.map {
            UniversalPronunciationResolver.derivedCandidateID(
                normalizedWord: $0.0,
                derivationBase: $0.1,
                derivationRuleID: $0.2,
                baseIPA: $0.3,
                derivedIPA: $0.4,
                candidatePackVersion: $0.5)
        }
        #expect(Set(candidateIDs).count == candidateIDs.count)
    }

    @Test func invalidCandidateIdentityInputsFailClosed() {
        #expect(
            UniversalPronunciationResolver.derivedCandidateID(
                normalizedWord: "Startable",
                derivationBase: "start",
                derivationRuleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: "morphology-v1:sha256:" + String(repeating: "0", count: 64))
                .isEmpty)
    }
}
