// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

func XCTAssertThrowsErrorAsync<T>(
    _ expr: @autoclosure () async throws -> T,
    _ handle: (Error) -> Void
) async {
    do {
        _ = try await expr()
        XCTFail("expected throw")
    } catch { handle(error) }
}
