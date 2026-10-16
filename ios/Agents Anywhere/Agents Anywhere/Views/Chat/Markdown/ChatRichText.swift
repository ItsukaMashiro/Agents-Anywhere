import Foundation

/// Splits assistant reply text into markdown and raw-HTML segments.
/// VCP-style replies embed self-contained `<div id="vcp-root">…</div>` cards;
/// the markdown pipeline would show their source, so those regions are handed
/// to an HTML renderer instead.
nonisolated enum ChatRichText {
    struct Segment: Equatable, Identifiable {
        let index: Int
        let isHTML: Bool
        let text: String
        var id: Int { index }
    }

    private static let rootMarker = "<div id=\"vcp-root\""

    static func segments(_ text: String) -> [Segment] {
        guard text.contains(rootMarker) else { return [Segment(index: 0, isHTML: false, text: text)] }
        var segments: [Segment] = []
        var plainStart = text.startIndex
        while let marker = text.range(of: rootMarker, range: plainStart..<text.endIndex) {
            if marker.lowerBound > plainStart {
                segments.append(Segment(index: segments.count, isHTML: false, text: String(text[plainStart..<marker.lowerBound])))
            }
            let end = htmlEnd(in: text, from: marker.lowerBound)
            segments.append(Segment(index: segments.count, isHTML: true, text: String(text[marker.lowerBound..<end])))
            plainStart = end
        }
        if plainStart < text.endIndex {
            segments.append(Segment(index: segments.count, isHTML: false, text: String(text[plainStart..<text.endIndex])))
        }
        return segments
    }

    /// Depth-matches `<div>`/`</div>` from the opening tag. An unterminated
    /// region (a reply that is still streaming) extends to the end of the text.
    private static func htmlEnd(in text: String, from start: String.Index) -> String.Index {
        var depth = 0
        var cursor = start
        while cursor < text.endIndex {
            let rest = text[cursor...]
            if rest.hasPrefix("</div>") {
                depth -= 1
                cursor = text.index(cursor, offsetBy: 6)
                if depth <= 0 { return cursor }
            } else if rest.hasPrefix("<div") {
                depth += 1
                cursor = text.index(cursor, offsetBy: 4)
            } else {
                cursor = text.index(after: cursor)
            }
        }
        return text.endIndex
    }

    /// Tavern game text arrives wrapped in `<content>…</content>` blocks. The
    /// tags are markup, not prose, so they are stripped and the reply renders
    /// as styled game prose. Returns nil unless the reply is game text.
    static func tavernContent(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<content>") else { return nil }
        var inner = trimmed.replacingOccurrences(of: "<content>", with: "")
        inner = inner.replacingOccurrences(of: "</content>", with: "")
        let result = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
