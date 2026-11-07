// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Help bodies carry inline markdown lead-ins. Rendered as a plain String,
/// SwiftUI showed the asterisks ("**Keeping files available offline:**").
@MainActor
struct HelpViewMarkdownTests {
    @Test func boldLeadInLosesItsAsterisks() {
        let rendered = HelpView.rendered("**Search:** Type any phrase.")
        let text = String(rendered.characters)
        #expect(text == "Search: Type any phrase.")
    }

    @Test func lineBreaksAndBulletsSurvive() {
        let body = "Intro line.\n\n• First\n• Second"
        let text = String(HelpView.rendered(body).characters)
        #expect(text == body)
    }

    @Test func everyHelpSectionRendersWithoutLiteralMarkers() {
        for section in HelpContent.sections {
            let text = String(HelpView.rendered(section.body).characters)
            #expect(!text.contains("**"), "\(section.title) still shows literal asterisks")
        }
    }

    @Test func boldLeadInBecomesASubheadParagraph() {
        let blocks = HelpView.blocks("Intro line.\n\n**Search:** Type any phrase.\n\n**Note** stays inline.")
        #expect(blocks.count == 3)
        #expect(blocks[0] == HelpView.HelpBlock(heading: nil, text: "Intro line."))
        #expect(blocks[1] == HelpView.HelpBlock(heading: "Search", text: "Type any phrase."))
        #expect(blocks[2].heading == nil)
    }

    @Test func everyHelpSectionKeepsItsTextAcrossBlocks() {
        for section in HelpContent.sections {
            let blocks = HelpView.blocks(section.body)
            #expect(!blocks.isEmpty, "\(section.title) has no paragraphs")
            for block in blocks {
                #expect(!(block.heading ?? "").contains("*"))
            }
        }
    }
}
