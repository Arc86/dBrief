import Foundation

/// Turns the `[hh:mm:ss]` citations chat answers carry into links that seek the
/// recording. The link is an app-internal URL handled by the chat view's
/// `openURL` action, never opened by the system.
enum ChatTimestampLink {
    static let scheme = "dbrief-seek"

    // A bracket group holding only timestamps and separators, e.g. [00:12:34]
    // or [00:12:34, 00:15:02] or [12:34–13:10]; then each timestamp inside it.
    private static let groupRegex = try! NSRegularExpression(pattern: #"\[[0-9:\s,;–—\-]+\]"#)
    private static let tokenRegex = try! NSRegularExpression(pattern: #"\d{1,2}(?::\d{2}){1,2}"#)

    /// Seconds for `hh:mm:ss` or `mm:ss`; nil when a field is out of range.
    static func seconds(from token: String) -> TimeInterval? {
        let fields = token.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(fields.count), fields.allSatisfy({ $0 != nil }) else { return nil }
        let values = fields.compactMap { $0 }
        guard values.dropFirst().allSatisfy({ (0..<60).contains($0) }), values[0] >= 0 else { return nil }
        return TimeInterval(values.reduce(0) { $0 * 60 + $1 })
    }

    static func url(seconds: TimeInterval) -> URL {
        URL(string: "\(scheme)://\(Int(seconds))")!
    }

    static func seconds(from url: URL) -> TimeInterval? {
        guard url.scheme == scheme, let host = url.host(), let value = Int(host), value >= 0 else { return nil }
        return TimeInterval(value)
    }

    /// Ranges (UTF-16, in `text`) of every timestamp inside a citation group, with its time.
    static func citations(in text: String) -> [(range: NSRange, seconds: TimeInterval)] {
        let ns = text as NSString
        var found: [(NSRange, TimeInterval)] = []
        for group in groupRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for token in tokenRegex.matches(in: text, range: group.range) {
                if let seconds = seconds(from: ns.substring(with: token.range)) {
                    found.append((token.range, seconds))
                }
            }
        }
        return found
    }

    /// `text` with each citation linked to its time.
    static func linked(_ text: AttributedString) -> AttributedString {
        let plain = String(text.characters)
        let citations = citations(in: plain)
        guard !citations.isEmpty else { return text }
        var result = text
        for citation in citations {
            guard let range = Range(citation.range, in: result) else { continue }
            result[range].link = url(seconds: citation.seconds)
        }
        return result
    }
}
