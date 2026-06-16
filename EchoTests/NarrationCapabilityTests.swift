// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationCapabilityTests {

    @Test func gatesIPhonesToA15Plus() {
        // A14 and older iPhones — unsupported (the BNNS trap).
        #expect(NarrationCapability.isSupported(modelIdentifier: "iPhone13,3") == false)  // 12 Pro, A14
        #expect(NarrationCapability.isSupported(modelIdentifier: "iPhone13,1") == false)  // 12 mini
        #expect(NarrationCapability.isSupported(modelIdentifier: "iPhone12,1") == false)  // 11, A13
        // A15 and newer — supported.
        #expect(NarrationCapability.isSupported(modelIdentifier: "iPhone14,2") == true)  // 13 Pro, A15
        #expect(NarrationCapability.isSupported(modelIdentifier: "iPhone15,2") == true)  // 14 Pro, A16
        #expect(NarrationCapability.isSupported(modelIdentifier: "iPhone17,1") == true)  // 16 Pro, A18
    }

    @Test func otherFamiliesDefaultSupported() {
        #expect(NarrationCapability.isSupported(modelIdentifier: "iPad13,1") == true)
        #expect(NarrationCapability.isSupported(modelIdentifier: "Mac15,3") == true)
        #expect(NarrationCapability.isSupported(modelIdentifier: "arm64") == true)  // odd/unknown → allow
    }
}
