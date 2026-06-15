import Testing

@testable import Echo

@Suite struct AlignmentAnchorSourceTests {
    @Test func synthesizedHasStableRawValue() {
        #expect(AlignmentAnchorRecord.Source.synthesized.rawValue == "synthesized")
    }

    @Test func synthesizedRoundTripsFromRawValue() {
        #expect(AlignmentAnchorRecord.Source(rawValue: "synthesized") == .synthesized)
    }
}
