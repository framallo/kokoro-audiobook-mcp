import Foundation

struct Chapter: Sendable { var title: String; var sentences: [String] }

enum KabError: Error { case parse(String); case proc(String) }

/// EPUB -> ordered chapters of sentences. Unzips via /usr/bin/unzip (no SPM zip
/// dependency), reads the OPF spine, strips HTML to text, and splits sentences
/// (Spanish/English aware: keeps dialogue em-dashes; respects . ! ? … ¿ ¡).
enum Epub {
    static func parse(_ epubPath: String) throws -> [Chapter] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kab-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try Proc.run("/usr/bin/unzip", ["-o", "-q", epubPath, "-d", tmp.path])

        let container = try String(contentsOf: tmp.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfRel = firstGroup(container, #"full-path=\"([^\"]+)\""#) else {
            throw KabError.parse("no OPF in container.xml")
        }
        let opfURL = tmp.appendingPathComponent(opfRel)
        let opfDir = opfURL.deletingLastPathComponent()
        let opf = try String(contentsOf: opfURL, encoding: .utf8)

        var idHref: [String: String] = [:]
        for item in allGroups(opf, #"<item\b[^>]*>"#) {
            guard let id = firstGroup(item, #"id=\"([^\"]+)\""#),
                  let href = firstGroup(item, #"href=\"([^\"]+)\""#) else { continue }
            idHref[id] = href
        }

        var chapters: [Chapter] = []
        for ref in allGroups(opf, #"<itemref\b[^>]*idref=\"([^\"]+)\"[^>]*>"#) {
            guard let id = firstGroup(ref, #"idref=\"([^\"]+)\""#),
                  let href = idHref[id] else { continue }
            let rel = href.removingPercentEncoding ?? href
            let fileURL = opfDir.appendingPathComponent(rel)
            guard let html = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let title = extractTitle(html) ?? "Chapter \(chapters.count + 1)"
            let sentences = splitSentences(stripHTML(html))
            if sentences.isEmpty { continue }
            chapters.append(Chapter(title: title, sentences: sentences))
        }
        if chapters.isEmpty { throw KabError.parse("no readable chapters in spine") }
        return chapters
    }

    static func extractTitle(_ html: String) -> String? {
        for pat in [#"<h1\b[^>]*>(.*?)</h1>"#, #"<h2\b[^>]*>(.*?)</h2>"#, #"<title\b[^>]*>(.*?)</title>"#] {
            if let raw = firstGroup(html, pat, dotAll: true) {
                let t = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    static func stripHTML(_ html: String) -> String {
        var s = html
        s = replace(s, #"(?s)<(script|style|head)\b.*?</\1>"#, "")
        s = replace(s, #"(?i)</(p|div|h[1-6]|li|br|tr)\s*>"#, " \n")
        s = replace(s, #"<[^>]+>"#, "")
        s = decodeEntities(s)
        s = replace(s, #"[ \t]+"#, " ")
        s = replace(s, #"\n[ \t]*\n+"#, "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
                   "&hellip;": "…", "&laquo;": "«", "&raquo;": "»"]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }

    /// Split into sentences on . ! ? … and closing ¿¡ blocks, keeping the
    /// terminator and any trailing closing quote with the sentence.
    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        for para in text.components(separatedBy: "\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            var current = ""
            let chars = Array(p)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                current.append(c)
                if c == "." || c == "!" || c == "?" || c == "…" {
                    // swallow trailing closing quotes/brackets
                    var j = i + 1
                    while j < chars.count, "\"”»')]".contains(chars[j]) { current.append(chars[j]); j += 1 }
                    // sentence ends if followed by space/end
                    if j >= chars.count || chars[j] == " " {
                        let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        if s.count > 1 { out.append(s) }
                        current = ""
                    }
                    i = j; continue
                }
                i += 1
            }
            let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.count > 1 { out.append(tail) }
        }
        return out
    }

    // -- tiny regex helpers --
    static func firstGroup(_ s: String, _ pattern: String, dotAll: Bool = false) -> String? {
        let opts: NSRegularExpression.Options = dotAll ? [.dotMatchesLineSeparators, .caseInsensitive] : [.caseInsensitive]
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
    static func allGroups(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: range).compactMap { m in
            Range(m.range, in: s).map { String(s[$0]) }
        }
    }
    static func replace(_ s: String, _ pattern: String, _ with: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: with)
    }
}
