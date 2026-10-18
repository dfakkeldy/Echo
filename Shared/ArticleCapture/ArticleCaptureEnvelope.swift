// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private nonisolated func articleWorkshopDateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

nonisolated enum ArticleCaptureMethod: String, Codable, Sendable {
    case safariRenderedPage
    case urlFetch
}

nonisolated struct ReadabilityCapturePayload: Codable, Equatable, Sendable {
    let sourceURL: String
    let canonicalURL: String?
    let title: String?
    let byline: String?
    let siteName: String?
    let language: String?
    let publishedTime: String?
    let excerpt: String?
    let contentXHTML: String
    let textContent: String
    let imageURLs: [String]
}

nonisolated struct ArticleCaptureEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let captureID: UUID
    let capturedAt: Date
    let method: ArticleCaptureMethod
    let sourceApplication: String?
    let payload: ReadabilityCapturePayload
}

extension JSONEncoder {
    nonisolated static var articleWorkshop: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(articleWorkshopDateFormatter().string(from: date))
        }
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var articleWorkshop: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = articleWorkshopDateFormatter().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date with fractional seconds.")
            }
            return date
        }
        return decoder
    }
}
