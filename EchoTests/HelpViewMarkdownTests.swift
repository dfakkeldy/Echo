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
}
