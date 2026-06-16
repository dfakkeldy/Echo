// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import Echo

/// Guards the EPUB extraction path against zip-slip (directory traversal).
/// A malicious `.epub` is just a ZIP; an entry whose path contains `../`
/// segments or is absolute must never resolve to a file outside the
/// extraction root.  See CODE_AUDIT.md §6.1.
struct EPUBExtractionPathSafetyTests {

    private let root = URL(fileURLWithPath: "/tmp/echo-epub-root", isDirectory: true)

    // MARK: - Malicious paths are rejected

    @Test(arguments: [
        "../escape.txt",                 // climbs out one level
        "../../etc/passwd",              // climbs out several levels
        "OEBPS/../../escape.txt",        // climbs out after descending
        "/etc/passwd",                   // absolute POSIX path
        "/escape.txt",                   // absolute, single component
    ])
    func rejectsTraversalAndAbsolutePaths(_ entryPath: String) throws {
        #expect(throws: (any Error).self) {
            _ = try EPUBAutoImportScanner.safeDestination(for: entryPath, within: root)
        }
    }

    // MARK: - Legitimate paths resolve inside the root

    @Test(arguments: [
        "mimetype",
        "OEBPS/content.opf",
        "OEBPS/text/chapter1.xhtml",
        "META-INF/container.xml",
    ])
    func acceptsPathsThatStayInsideRoot(_ entryPath: String) throws {
        let resolved = try EPUBAutoImportScanner.safeDestination(for: entryPath, within: root)

        // The resolved file must live under the root directory…
        #expect(resolved.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        // …and end with the entry's own path components.
        #expect(resolved.standardizedFileURL.path.hasSuffix(entryPath))
    }

    /// A path that dips into `..` but stays within the root is still safe and
    /// must resolve to its normalized in-root location.
    @Test func normalizesInRootTraversalWithoutEscaping() throws {
        let resolved = try EPUBAutoImportScanner.safeDestination(
            for: "OEBPS/text/../images/cover.png", within: root
        )
        #expect(resolved.standardizedFileURL.path == root.standardizedFileURL.path + "/OEBPS/images/cover.png")
    }
}
