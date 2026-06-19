// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationPrepareStatusTests {
    @Test func mapsMonotonicallyIntoTheReservedFirstBand() {
        let d0 = NarrationPrepareStatus.batch(for: .downloadingModels(fraction: 0))
        let d1 = NarrationPrepareStatus.batch(for: .downloadingModels(fraction: 1))
        let c0 = NarrationPrepareStatus.batch(for: .compilingModels(done: 0, total: 20))
        let c1 = NarrationPrepareStatus.batch(for: .compilingModels(done: 20, total: 20))
        let ready = NarrationPrepareStatus.batch(for: .ready)

        #expect(d0.fraction == 0)
        #expect(d1.fraction <= c0.fraction)  // download band ends at/below compile band start
        #expect(c1.fraction <= ready.fraction)
        #expect(ready.fraction == 0.15)  // never exceeds the reserved prepare band
        #expect(d1.message.contains("100%"))
        #expect(c0.message == "Compiling voice models… 0 of 20")
    }

    @Test func compileTotalZeroDoesNotDivideByZero() {
        let s = NarrationPrepareStatus.batch(for: .compilingModels(done: 0, total: 0))
        #expect(s.fraction.isFinite)
    }
}
