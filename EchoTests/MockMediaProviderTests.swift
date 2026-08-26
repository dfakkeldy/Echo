// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Testing

@testable import Echo

@Suite struct MockMediaProviderTests {
    @Test func gatsbyScreenshotArgumentPrefersSampleBook() {
        #expect(
            MockMediaProvider.prefersSampleBook(
                arguments: [MockMediaProvider.forceSampleBookLaunchArgument]))
        #expect(!MockMediaProvider.prefersSampleBook(arguments: []))
    }

    @Test func screenshotAppearanceArgumentPrefersDarkMode() {
        #expect(
            MockMediaProvider.prefersDarkAppearance(
                arguments: [MockMediaProvider.forceDarkAppearanceLaunchArgument]))
        #expect(!MockMediaProvider.prefersDarkAppearance(arguments: []))
    }
}
#endif
