import Foundation

enum AlignmentError: LocalizedError, Equatable {
    case notAnEPUB(path: String)
    case missingOPF
    case spineEmpty
    case transcriptEmpty(path: String)
    case alignmentFailed(confidence: Double)
    case unsupportedEPUBVersion(String)
    case corruptXHTML(item: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .notAnEPUB(let path):
            return "File is not a valid EPUB (missing mimetype): \(path)"
        case .missingOPF:
            return "EPUB is missing content.opf or container.xml"
        case .spineEmpty:
            return "EPUB spine contains no items — nothing to align"
        case .transcriptEmpty(let path):
            return "Transcript file has no segments: \(path)"
        case .alignmentFailed(let confidence):
            return "Alignment failed with global confidence \(String(format: "%.2f", confidence)) — transcript may not match this EPUB"
        case .unsupportedEPUBVersion(let version):
            return "Unsupported EPUB version: \(version)"
        case .corruptXHTML(let item, let reason):
            return "Corrupt XHTML in \(item): \(reason)"
        }
    }
}
