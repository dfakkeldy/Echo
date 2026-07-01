// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import EchoCore

@Suite struct FMNormalizerTests {
    @Test func cacheHitReturnsCachedValue() async {
        let cache = FMNormalizationCache()
        let key = FMNormalizationCache.key(for: "hello world")
        await cache.set(key: key, value: "cached result")
        let result = await cache.get(key: key)
        #expect(result == "cached result")
    }

    @Test func cacheMissReturnsNil() async {
        let cache = FMNormalizationCache()
        let result = await cache.get(key: "nonexistent")
        #expect(result == nil)
    }

    @Test func cacheKeyIsStable() {
        let k1 = FMNormalizationCache.key(for: "the quick brown fox")
        let k2 = FMNormalizationCache.key(for: "the quick brown fox")
        #expect(k1 == k2)
    }

    @Test func cacheKeyDiffersForDifferentText() {
        let k1 = FMNormalizationCache.key(for: "hello")
        let k2 = FMNormalizationCache.key(for: "world")
        #expect(k1 != k2)
    }

    @Test func refineReturnsInputWhenNoFMChanges() async {
        // FM is unavailable in unit test context (no FoundationModels on iOS Sim),
        // so refine should always pass through.
        let cache = FMNormalizationCache()
        let result = await FMNormalizer.refine("hello world", cache: cache)
        #expect(result == "hello world")
    }

    @Test func refineUsesCacheOnSecondCall() async {
        let cache = FMNormalizationCache()
        let text = "PCalc is a calculator app"

        // First call: FM unavailable, returns input.
        let r1 = await FMNormalizer.refine(text, cache: cache)
        #expect(r1 == text)

        // Manually seed the cache with a refinement to simulate FM having run.
        let key = FMNormalizationCache.key(for: text)
        await cache.set(key: key, value: "P Calc is a calculator app")

        // Second call should hit cache.
        let r2 = await FMNormalizer.refine(text, cache: cache)
        #expect(r2 == "P Calc is a calculator app")
    }
}
