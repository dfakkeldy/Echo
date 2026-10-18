// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Client-side JSON recovery for conservative provider dialects that may return
/// an object raw, fenced, or wrapped in prose.
nonisolated enum LooseJSONExtractor {
    /// Returns the first balanced, `JSONSerialization`-valid top-level JSON object.
    static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else {
                index += 1
                continue
            }
            if let candidate = balancedObject(in: chars, from: index),
                (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) is [String: Any]
            {
                return candidate
            }
            index += 1
        }
        return nil
    }

    private static func balancedObject(in chars: [Character], from start: Int) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < chars.count {
            let char = chars[index]
            if escaped {
                escaped = false
            } else if inString, char == "\\" {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(chars[start...index])
                    }
                }
            }
            index += 1
        }
        return nil
    }
}
