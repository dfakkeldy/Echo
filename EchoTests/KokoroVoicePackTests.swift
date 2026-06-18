// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct KokoroVoicePackTests {

    @Test func loadsBundledAfHeart() throws {
        let pack = try KokoroVoicePack(named: "af_heart")
        // 510 rows × 256 dims (matches Kokoro MAX_PHONEME_LENGTH = 510).
        #expect(pack.rows == 510)
    }

    @Test func refSReturns256Floats() throws {
        let pack = try KokoroVoicePack(named: "af_heart")
        #expect(pack.refS(forPhonemeCount: 1).count == 256) // row 0
        #expect(pack.refS(forPhonemeCount: 50).count == 256) // row 49
    }

    @Test func refSClampsToLastRowWithoutCrash() throws {
        let pack = try KokoroVoicePack(named: "af_heart")
        // 100k phonemes >> 510 rows → clamp to the last row, no out-of-range.
        let huge = pack.refS(forPhonemeCount: 100_000)
        let last = pack.refS(forPhonemeCount: 510)
        #expect(huge.count == 256)
        #expect(huge == last)
    }

    @Test func refSClampsPhonemeCountZeroToFirstRow() throws {
        let pack = try KokoroVoicePack(named: "af_heart")
        // n-1 = -1 → clamp to 0.
        let first = pack.refS(forPhonemeCount: 0)
        #expect(first.count == 256)
        #expect(first == pack.refS(forPhonemeCount: 1))
    }

    @Test func allRefSValuesAreFinite() throws {
        // Sanity: the bundled Float32 blob must not contain NaN/inf.
        let pack = try KokoroVoicePack(named: "af_heart")
        let row = pack.refS(forPhonemeCount: 1)
        #expect(row.allSatisfy { $0.isFinite })
    }
}
