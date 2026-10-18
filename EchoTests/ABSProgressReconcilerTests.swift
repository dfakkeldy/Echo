// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ABSProgressReconcilerTests {
    @Test func noRemotePushesLocal() {
        #expect(
            ABSProgressReconciler.decide(
                localTime: 100, localUpdatedAt: 5, remoteTime: nil, remoteUpdatedAt: nil)
                == .pushLocal)
    }
    @Test func remoteTimeWithoutTimestampPushesLocal() {
        #expect(
            ABSProgressReconciler.decide(
                localTime: 100, localUpdatedAt: 5, remoteTime: 300, remoteUpdatedAt: nil)
                == .pushLocal)
    }
    @Test func remoteNewerAndDifferentSeeksLocal() {
        #expect(
            ABSProgressReconciler.decide(
                localTime: 100, localUpdatedAt: 1000, remoteTime: 300, remoteUpdatedAt: 2000)
                == .seekLocalTo(300))
    }
    @Test func localNewerPushes() {
        #expect(
            ABSProgressReconciler.decide(
                localTime: 300, localUpdatedAt: 2000, remoteTime: 100, remoteUpdatedAt: 1000)
                == .pushLocal)
    }
    @Test func remoteNewerButCloseIsNoop() {
        #expect(
            ABSProgressReconciler.decide(
                localTime: 100, localUpdatedAt: 1000, remoteTime: 102, remoteUpdatedAt: 2000)
                == .noop)
    }
    @Test func equalTimestampsNoop() {
        #expect(
            ABSProgressReconciler.decide(
                localTime: 100, localUpdatedAt: 1000, remoteTime: 300, remoteUpdatedAt: 1000)
                == .noop)
    }
    @Test func noLocalStampTrustsRemote() {
        #expect(
            ABSProgressReconciler.decide(
                localTime: 100, localUpdatedAt: nil, remoteTime: 300, remoteUpdatedAt: 2000)
                == .seekLocalTo(300))
    }
}
