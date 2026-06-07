import Foundation

/// Analyzes EPUB XHTML blocks to infer structural semantics (e.g. what is a heading
/// vs a paragraph) using a heuristic scoring approach.
struct EPUBHeuristicEngine {
    let tocLabels: [String]
    let spineItemCount: Int
    
    // Frequency map of CSS classes used on heading-like elements.
    var cssFrequencyMap: [String: Int] = [:]
    
    init(tocLabels: [String], spineItemCount: Int) {
        self.tocLabels = tocLabels
        self.spineItemCount = spineItemCount
    }
    
    /// Pass 1: Build the CSS Fingerprint Map
    /// Scans all blocks across the entire book to build a frequency map of class names.
    mutating func buildCSSFingerprint(from blocks: [TextBlockDescriptor]) {
        for block in blocks {
            let isHeading = block.rawTags.lowercased().hasPrefix("h")
            let textCount = block.text?.count ?? 0
            let isShort = textCount > 0 && textCount < 100
            
            // Only consider headings or short structural blocks to prevent diluting the map with generic body text
            if isHeading || isShort {
                for className in block.rawClasses {
                    cssFrequencyMap[className, default: 0] += 1
                }
            }
        }
    }
    
    /// Pass 2: The Scoring Engine
    /// Assigns EPubBlockRecord.Kind based on heuristic signals.
    func score(block: TextBlockDescriptor) -> EPubBlockRecord.Kind {
        // We only modify paragraph/heading types. Images and other types are left alone.
        guard block.kind == .paragraph || block.kind == .heading else {
            return block.kind
        }
        
        let cleanText = block.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleanText.isEmpty {
            return .paragraph
        }
        
        var score = 0
        
        // 1. Exact TOC Match (+100)
        if tocLabels.contains(where: { $0.caseInsensitiveCompare(cleanText) == .orderedSame }) {
            score += 100
        }
        
        // 2. <h1> or <h2> Tag (+90 for h1/h2, +70 for h3/h4/h5/h6)
        let tag = block.rawTags.lowercased()
        if tag == "h1" || tag == "h2" {
            score += 90
        } else if tag.hasPrefix("h") && tag.count == 2 {
            score += 70
        }
        
        // 3. Starts with "Chapter / Part" (+70)
        if cleanText.range(of: "^(?:chapter|part)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            score += 70
        }
        
        // 4. CSS Class Frequency Match (+60)
        for className in block.rawClasses {
            if let count = cssFrequencyMap[className] {
                // Heuristic: if it's used roughly once per spine item, it's highly likely a structural heading.
                if count > 0 && count <= (spineItemCount + 5) {
                    score += 60
                    break
                }
            }
        }
        
        // 5. Visual formatting: ALL CAPS (+20)
        if cleanText == cleanText.uppercased() && cleanText.count > 3 && cleanText.rangeOfCharacter(from: .letters) != nil {
            score += 20
        }
        
        // 6. Visual formatting: Very Short Line (+15)
        if cleanText.count < 60 {
            score += 15
        }
        
        // Determine kind based on score threshold
        // 80 points is the threshold to become a heading.
        if score >= 80 {
            return .heading
        } else {
            return .paragraph
        }
    }
}
