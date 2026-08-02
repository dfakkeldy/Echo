// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct EPUBImageBlockParsingTests {
    @Test func figureCaptionBecomesImageTextWhileAltRemainsFallback() throws {
        let xhtml = Data(
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <figure><img src="../images/photo.png" alt="Harbour at sunrise"/>
                <figcaption>Fishing boats returning home.</figcaption></figure>
              <img src="../images/diagram.png" alt="Process diagram"/>
            </body></html>
            """.utf8)

        let parsed = parseXHTML(from: xhtml)
        let images = parsed.blocks.filter { $0.kind == .image }

        #expect(images.count == 2)
        #expect(images[0].imagePath == "../images/photo.png")
        #expect(images[0].text == "Fishing boats returning home.")
        #expect(images[1].imagePath == "../images/diagram.png")
        #expect(images[1].text == "Process diagram")
    }
}
