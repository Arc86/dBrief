import Foundation

/// The body of an Apple Notes note as HTML, which Notes renders as rich text.
/// The summary's Markdown goes through `NotionMarkdown`, so headings, bold
/// section labels, lists and inline styles look the same as in Notion. Notes
/// names the note after its first line, so the body starts with the title.
enum AppleNotesHTML {
    static func body(for bundle: IntegrationContentBundle, fields: [DeliveryField], meetingInfo: [String] = [],
                     locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var html = ["<h1>\(escape(bundle.title))</h1>",
                    "<div>\(escape("\(formatter.string(from: bundle.createdAt)) · \(NotionAPI.duration(bundle.durationSeconds))"))</div>"]
        if fields.contains(.summary), let summary = nonEmpty(bundle.summary) {
            html.append("<h2>Summary</h2>")
            html.append(render(NotionMarkdown.blocks(from: summary)))
        }
        if fields.contains(.meetingInfo), !meetingInfo.isEmpty {
            html.append("<h2>Meeting info</h2>")
            html += meetingInfo.map { "<div>\(escape($0))</div>" }
        }
        let actions = ActionItemText.deliverable(bundle.actionItems).map(\.title)
        if fields.contains(.actionItems), !actions.isEmpty {
            html.append("<h2>Action items</h2>")
            html.append("<ul>" + actions.map { "<li>\(inline(NotionMarkdown.richText($0)))</li>" }.joined() + "</ul>")
        }
        let tags = ObsidianTag.sanitizeAll(bundle.tags)
        if fields.contains(.tags), !tags.isEmpty {
            html.append("<h2>Tags</h2>")
            html.append("<div>\(escape(tags.map { "#\($0)" }.joined(separator: " ")))</div>")
        }
        if fields.contains(.sentiment), let sentiment = nonEmpty(bundle.sentiment) {
            html.append("<h2>Sentiment</h2>")
            html.append("<div>\(escape(sentiment))</div>")
        }
        if fields.contains(.markdown), let markdown = nonEmpty(bundle.markdown) {
            html.append("<h2>Markdown</h2>")
            html += lines(markdown)
        }
        if fields.contains(.transcript), let transcript = nonEmpty(bundle.transcript) {
            html.append("<h2>Transcript</h2>")
            html += lines(transcript)
        }
        return html.joined(separator: "\n")
    }

    /// Notion blocks as HTML; consecutive list items share one list.
    static func render(_ blocks: [[String: Any]]) -> String {
        var html: [String] = []
        var openList: String?
        func closeList() {
            if let tag = openList { html.append("</\(tag)>") }
            openList = nil
        }
        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            let content = (block[type] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? []
            let text = inline(content)
            let list: String? = switch type {
            case "bulleted_list_item", "to_do": "ul"
            case "numbered_list_item": "ol"
            default: nil
            }
            if list != openList {
                closeList()
                if let list { html.append("<\(list)>"); openList = list }
            }
            switch type {
            case "bulleted_list_item", "numbered_list_item", "to_do": html.append("<li>\(text)</li>")
            case "heading_1", "heading_2", "heading_3": html.append("<h3>\(text)</h3>")
            case "quote": html.append("<blockquote>\(text)</blockquote>")
            case "divider": html.append("<hr>")
            default: html.append("<div>\(text)</div><div><br></div>")
            }
        }
        closeList()
        return html.joined()
    }

    /// Notion rich-text runs as inline HTML.
    static func inline(_ runs: [[String: Any]]) -> String {
        runs.map { run in
            let text = run["text"] as? [String: Any]
            var html = escape(text?["content"] as? String ?? "")
            let style = run["annotations"] as? [String: Bool] ?? [:]
            if style["code"] == true { html = "<tt>\(html)</tt>" }
            if style["strikethrough"] == true { html = "<strike>\(html)</strike>" }
            if style["italic"] == true { html = "<i>\(html)</i>" }
            if style["bold"] == true { html = "<b>\(html)</b>" }
            if let url = (text?["link"] as? [String: Any])?["url"] as? String {
                html = "<a href=\"\(escape(url))\">\(html)</a>"
            }
            return html
        }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<div>\(escape($0))</div>" }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
