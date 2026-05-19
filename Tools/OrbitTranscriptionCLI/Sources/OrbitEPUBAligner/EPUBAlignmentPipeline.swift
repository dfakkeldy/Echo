import Foundation

public struct EPUBAlignmentPipeline {
    private let unpacker = EPUBUnpacker()
    private let opfParser = OPFParser()
    private let xhtmlParser = XHTMLParser()
    private let aligner: TextAlignmentService
    private let injector = MarkerInjector()

    public init(aligner: TextAlignmentService = SlidingWindowAligner()) {
        self.aligner = aligner
    }

    public func process(
        epubPath: String,
        transcriptPath: String
    ) async throws -> [EnhancedTranscriptionSegment] {
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        let transcriptData = try Data(contentsOf: transcriptURL)
        let plainSegments = try JSONDecoder().decode([PlainSegment].self, from: transcriptData)

        guard !plainSegments.isEmpty else {
            throw AlignmentError.transcriptEmpty(path: transcriptPath)
        }

        let epubURL = URL(fileURLWithPath: epubPath)
        let unpackResult = try unpacker.unzip(epubURL)
        defer {
            try? FileManager.default.removeItem(at: unpackResult.tempDir)
        }

        let opfPath = try resolveOPFPath(from: unpackResult)
        var structure = try opfParser.parse(opfURL: opfPath, epubRoot: unpackResult.tempDir)
        structure = try populateSpineText(structure: structure, epubRoot: unpackResult.tempDir)

        let (fullText, allMarkers, allFormats) = concatenateSpine(structure.spine)

        let inputSegments = plainSegments.enumerated().map { index, seg in
            EnhancedTranscriptionSegment(
                sequenceIndex: index,
                text: seg.text,
                startTime: seg.startTime,
                endTime: seg.endTime
            )
        }

        let alignmentResults = try await aligner.align(epubText: fullText, transcript: inputSegments)
        let enrichedAlignments = attachMarkersToAlignments(alignmentResults, markers: allMarkers)

        let merged = injector.inject(markers: allMarkers, alignments: enrichedAlignments, segments: inputSegments)

        // Assign final monotonic sequence indices.
        return merged.enumerated().map { index, segment in
            EnhancedTranscriptionSegment(
                sequenceIndex: index,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                markers: segment.markers,
                formatting: segment.formatting
            )
        }
    }

    // MARK: - Private helpers

    private func resolveOPFPath(from unpackResult: EPUBUnpackResult) throws -> URL {
        if FileManager.default.fileExists(atPath: unpackResult.opfPath.path) {
            return unpackResult.opfPath
        }
        let relativePath = try opfParser.findOPFPath(from: unpackResult.containerXMLPath)
        let resolved = unpackResult.tempDir.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw AlignmentError.missingOPF
        }
        return resolved
    }

    private func populateSpineText(structure: EPUBStructure, epubRoot: URL) throws -> EPUBStructure {
        var items = structure.spine
        for i in 0..<items.count {
            let href = items[i].href
            let fullPath = epubRoot.appendingPathComponent("OEBPS").appendingPathComponent(href)
            if FileManager.default.fileExists(atPath: fullPath.path),
               let xhtml = try? String(contentsOf: fullPath, encoding: .utf8) {
                let parseResult = try xhtmlParser.parse(xhtml: xhtml, baseHref: href)
                items[i] = SpineItem(
                    id: items[i].id,
                    href: href,
                    mediaType: items[i].mediaType,
                    rawText: parseResult.rawText,
                    markers: parseResult.markers,
                    textFormats: parseResult.textFormats
                )
            }
        }
        return EPUBStructure(title: structure.title, author: structure.author, spine: items)
    }

    private func concatenateSpine(_ spine: [SpineItem]) -> (fullText: String, markers: [SyncMarker], formats: [TextFormat]) {
        var text = ""
        var allMarkers: [SyncMarker] = []
        var allFormats: [TextFormat] = []

        for item in spine {
            let baseOffset = text.count
            text += item.rawText + " "

            for marker in item.markers {
                allMarkers.append(SyncMarker(
                    type: marker.type,
                    payload: marker.payload,
                    epubCharOffset: marker.epubCharOffset + baseOffset
                ))
            }
            for format in item.textFormats {
                allFormats.append(TextFormat(
                    type: format.type,
                    range: (format.range.lowerBound + baseOffset)...(format.range.upperBound + baseOffset)
                ))
            }
        }

        return (text, allMarkers, allFormats)
    }

    private func attachMarkersToAlignments(
        _ alignments: [AlignmentResult],
        markers: [SyncMarker]
    ) -> [AlignmentResult] {
        alignments.map { alignment in
            let contained = markers.filter { alignment.epubCharRange.contains($0.epubCharOffset) }
            return AlignmentResult(
                epubCharRange: alignment.epubCharRange,
                transcriptTimeRange: alignment.transcriptTimeRange,
                confidence: alignment.confidence,
                containedMarkers: contained
            )
        }
    }
}

struct PlainSegment: Codable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}
