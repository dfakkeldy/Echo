// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing

@testable import Echo

@Suite struct ABSCertificateFingerprintTests {
    @Test func hexIsLowercase64Chars() {
        let digest = SHA256.hash(data: Data([0x00, 0x01, 0xab, 0xff]))
        let hex = ABSCertificateFingerprint.hex(digest)
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        #expect(!hex.contains(":"))
    }

    @Test func displayGroupsIntoUppercaseColonPairs() {
        #expect(ABSCertificateFingerprint.display("ab12cd") == "AB:12:CD")
    }

    @Test func displayHandlesOddTrailingNibbleWithoutCrashing() {
        // Defensive: never crash on malformed input; last group may be a single char.
        #expect(ABSCertificateFingerprint.display("abc") == "AB:C")
    }
}
