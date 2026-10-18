// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import OSLog

#if canImport(MetricKit)
    import MetricKit
#endif

@MainActor
final class MetricKitDiagnosticsController: NSObject {
    static let shared = MetricKitDiagnosticsController()

    private let archive: MetricKitDiagnosticsArchive
    private let logger = Logger(category: "MetricKitDiagnostics")
    private var isStarted = false

    init(archive: MetricKitDiagnosticsArchive? = nil) {
        self.archive = archive ?? Self.defaultArchive()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        #if canImport(MetricKit)
            MXMetricManager.shared.add(self)
            storeDiagnosticPayloads(MXMetricManager.shared.pastDiagnosticPayloads)
        #endif
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        #if canImport(MetricKit)
            MXMetricManager.shared.remove(self)
        #endif
    }

    deinit {
        #if canImport(MetricKit)
            if isStarted {
                MXMetricManager.shared.remove(self)
            }
        #endif
    }

    func storePayloadData(_ payloads: [Data], receivedAt: Date = Date()) {
        do {
            let urls = try archive.storeDiagnosticPayloads(payloads, receivedAt: receivedAt)
            if !urls.isEmpty {
                logger.info(
                    "Archived \(urls.count, privacy: .public) MetricKit diagnostic payload(s).")
            }
        } catch {
            logger.error(
                "MetricKit diagnostic archive failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func defaultArchive() -> MetricKitDiagnosticsArchive {
        MetricKitDiagnosticsArchive(
            directory: FileLocations.applicationSupportDirectory
                .appending(path: "MetricKitDiagnostics", directoryHint: .isDirectory),
            maxRetainedPayloads: 30
        )
    }
}

#if canImport(MetricKit)
    nonisolated private struct MetricDiagnosticPayloadBatch: @unchecked Sendable {
        let payloads: [MXDiagnosticPayload]
    }

    extension MetricKitDiagnosticsController: MXMetricManagerSubscriber {
        nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
            let batch = MetricDiagnosticPayloadBatch(payloads: payloads)
            Task { @MainActor [weak self, batch] in
                self?.storeDiagnosticPayloads(batch.payloads)
            }
        }

        nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
            // The v1.0 crash-free gate needs diagnostics, while App Store Connect
            // remains the source of aggregate crash-free session percentages.
        }

        private func storeDiagnosticPayloads(_ payloads: [MXDiagnosticPayload]) {
            storePayloadData(payloads.map { Data($0.jsonRepresentation()) })
        }
    }
#endif
