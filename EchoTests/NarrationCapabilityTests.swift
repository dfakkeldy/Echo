// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationCapabilityTests {

    @Test func narrationSupportedOnAllDevices() {
        // The ONNX (CPU) engine never touches the ANE, so the former A14 BNNS-trap
        // gate (A15+) is gone — every device that meets the deployment floor narrates.
        #expect(NarrationCapability.supportsOnDeviceNarration == true)
    }
}
