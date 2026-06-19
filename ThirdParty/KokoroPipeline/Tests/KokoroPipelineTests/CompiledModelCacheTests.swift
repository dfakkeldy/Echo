// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import KokoroPipeline

@Suite struct CompiledModelCacheTests {
    @Test func compilesOnceThenReusesCache() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let cache = tmp.appendingPathComponent("compiled", isDirectory: true)
        let package = tmp.appendingPathComponent("m.mlpackage")

        var compileCount = 0
        // Stub compile: emit a fresh fake .mlmodelc dir each call (mimics
        // MLModel.compileModel returning a new temp URL).
        let compile: (URL) throws -> URL = { _ in
            compileCount += 1
            let out = tmp.appendingPathComponent("\(UUID().uuidString).mlmodelc", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            return out
        }

        let first = try KokoroPipeline.ensureCompiledModel(
            name: "m", cacheDir: cache, compile: compile, package: package)
        let second = try KokoroPipeline.ensureCompiledModel(
            name: "m", cacheDir: cache, compile: compile, package: package)

        #expect(compileCount == 1)  // second call is a cache hit
        #expect(first == second)
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("m.mlmodelc").path))
    }

    @Test func nilCacheDirAlwaysCompiles() throws {
        var n = 0
        let compile: (URL) throws -> URL = { _ in
            n += 1
            return URL(fileURLWithPath: "/tmp/x\(n).mlmodelc")
        }
        _ = try KokoroPipeline.ensureCompiledModel(
            name: "m", cacheDir: nil, compile: compile,
            package: URL(fileURLWithPath: "/tmp/m.mlpackage"))
        _ = try KokoroPipeline.ensureCompiledModel(
            name: "m", cacheDir: nil, compile: compile,
            package: URL(fileURLWithPath: "/tmp/m.mlpackage"))
        #expect(n == 2)  // no cache → compile every call (current behavior preserved)
    }
}
