// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

nonisolated enum AnthologyBuildManifestValidationError: Error, Equatable, Sendable {
    case invalidReceipt
    case invalidManifest
}

nonisolated enum AnthologyBuildManifestValidator {
    static func validate(_ build: AnthologyBuildRecord) throws -> AnthologyBuildManifest {
        guard build.status == "succeeded",
            UUID(uuidString: build.id) != nil,
            UUID(uuidString: build.anthologyID) != nil,
            build.revision > 0,
            date(build.createdAt) != nil
        else {
            throw AnthologyBuildManifestValidationError.invalidReceipt
        }

        let data = Data(build.manifestJSON.utf8)
        guard sha256(data) == build.manifestSHA256 else {
            throw AnthologyBuildManifestValidationError.invalidReceipt
        }

        let manifest: AnthologyBuildManifest
        do {
            manifest = try JSONDecoder.articleWorkshop.decode(
                AnthologyBuildManifest.self,
                from: data)
        } catch {
            throw AnthologyBuildManifestValidationError.invalidManifest
        }

        guard [1, 2].contains(manifest.schemaVersion),
            manifest.anthologyID.uuidString == build.anthologyID,
            manifest.revision == build.revision,
            manifest.epubIdentifier == build.epubIdentifier,
            manifest.epubIdentifier == "urn:uuid:\(manifest.anthologyID.uuidString)",
            optionalText(manifest.title) != nil,
            optionalText(manifest.creator) != nil,
            validLanguage(manifest.language),
            (try? coverPath(manifest.coverPath)) == manifest.coverPath,
            manifest.chapters.isEmpty == false,
            manifest.chapters.map(\.order) == Array(0..<manifest.chapters.count),
            Set(manifest.chapters.map(\.entryID)).count == manifest.chapters.count,
            Set(manifest.chapters.map(\.captureID)).count == manifest.chapters.count,
            Set(manifest.chapters.map(\.articleRevisionID)).count == manifest.chapters.count,
            Set(manifest.chapters.map(\.stableSlot)).count == manifest.chapters.count,
            manifest.chapters.allSatisfy({ chapter in
                chapter.stableSlot >= 0
                    && optionalText(chapter.title) != nil
                    && httpURL(chapter.sourceURL.absoluteString) == chapter.sourceURL
                    && (chapter.voiceID.flatMap(optionalText).map {
                        VoiceCatalog.voice(for: VoiceID($0)) != nil
                    } ?? true)
                    && validSHA256(chapter.readableContentSHA256)
                    && chapter.readableContentSHA256
                        == ArticleWorkshopDigest.readableContent(blocks: chapter.blocks)
                    && Set(chapter.blocks.map(\.id)).count == chapter.blocks.count
                    && chapter.blocks.allSatisfy { optionalText($0.id) != nil }
                    && chapter.blocks.allSatisfy { block in
                        (block.sourceURL.map {
                            httpURL($0.absoluteString) == $0
                        } ?? true)
                            && (block.imageCandidateURL.map {
                                httpURL($0.absoluteString) == $0
                            } ?? true)
                    }
            })
        else {
            throw AnthologyBuildManifestValidationError.invalidManifest
        }
        return manifest
    }

    private static func optionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func coverPath(_ value: String?) throws -> String? {
        guard let path = optionalText(value) else { return nil }
        guard path == URL(fileURLWithPath: path).lastPathComponent,
            path != ".",
            path != ".."
        else {
            throw AnthologyBuildManifestValidationError.invalidManifest
        }
        return path
    }

    private static func validLanguage(_ value: String) -> Bool {
        value == "und"
            || value.range(
                of: #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"#,
                options: .regularExpression) != nil
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func httpURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil,
            components.password == nil
        else {
            return nil
        }
        return url
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
