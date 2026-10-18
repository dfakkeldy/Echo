// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Guards the isolation guarantee the ABS suites depend on. Swift Testing runs
/// suites, and the tests inside them, concurrently in one process, so two tests
/// stubbing the same path suffix at the same time is the normal case rather than
/// the exceptional one. These tests fail if scoping ever stops separating them.
@MainActor
@Suite struct URLProtocolStubScopeTests {
    private func freshScope(_ label: String) -> String {
        let scope = "stub-scope-\(label)-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        return scope
    }

    @Test func concurrentScopesRecordOnlyTheirOwnRequests() async throws {
        let first = freshScope("first")
        let second = freshScope("second")
        defer {
            URLProtocolStub.finish(scope: first)
            URLProtocolStub.finish(scope: second)
        }
        URLProtocolStub.stub(scope: first, pathSuffix: "/probe", json: #"{"who":"first"}"#)
        URLProtocolStub.stub(scope: second, pathSuffix: "/probe", json: #"{"who":"second"}"#)
        let firstSession = URLProtocolStub.makeSession(scope: first)
        let secondSession = URLProtocolStub.makeSession(scope: second)

        async let firstBody = firstSession.data(from: URL(string: "http://h/first/probe")!).0
        async let secondBody = secondSession.data(from: URL(string: "http://h/second/probe")!).0
        let (firstData, secondData) = try await (firstBody, secondBody)

        // Same path suffix, same instant, different canned bodies.
        #expect(String(decoding: firstData, as: UTF8.self) == #"{"who":"first"}"#)
        #expect(String(decoding: secondData, as: UTF8.self) == #"{"who":"second"}"#)

        let firstPaths = URLProtocolStub.requests(scope: first).compactMap { $0.url?.path }
        let secondPaths = URLProtocolStub.requests(scope: second).compactMap { $0.url?.path }
        #expect(firstPaths == ["/first/probe"])
        #expect(secondPaths == ["/second/probe"])
    }

    @Test func resettingOneScopeLeavesAnotherScopeIntact() async throws {
        let kept = freshScope("kept")
        let cleared = freshScope("cleared")
        defer {
            URLProtocolStub.finish(scope: kept)
            URLProtocolStub.finish(scope: cleared)
        }
        URLProtocolStub.stub(scope: kept, pathSuffix: "/probe", json: #"{"who":"kept"}"#)
        URLProtocolStub.stub(scope: cleared, pathSuffix: "/probe", json: #"{"who":"cleared"}"#)
        let keptSession = URLProtocolStub.makeSession(scope: kept)
        let clearedSession = URLProtocolStub.makeSession(scope: cleared)
        _ = try await keptSession.data(from: URL(string: "http://h/kept/probe")!)
        _ = try await clearedSession.data(from: URL(string: "http://h/cleared/probe")!)

        // This is what a neighbouring test's fixture does when it starts up.
        URLProtocolStub.reset(scope: cleared)

        #expect(URLProtocolStub.requests(scope: cleared).isEmpty)
        #expect(URLProtocolStub.requests(scope: kept).count == 1)

        // The surviving scope's stub must still answer, not fall through to 404.
        let (body, _) = try await keptSession.data(from: URL(string: "http://h/kept/probe")!)
        #expect(String(decoding: body, as: UTF8.self) == #"{"who":"kept"}"#)
    }

    @Test func finishingAScopeDropsItsRecordedRequests() async throws {
        let scope = freshScope("finished")
        URLProtocolStub.stub(scope: scope, pathSuffix: "/probe", json: "{}")
        let session = URLProtocolStub.makeSession(scope: scope)
        _ = try await session.data(from: URL(string: "http://h/probe")!)
        #expect(URLProtocolStub.requests(scope: scope).count == 1)

        URLProtocolStub.finish(scope: scope)

        #expect(URLProtocolStub.requests(scope: scope).isEmpty)
    }
}
