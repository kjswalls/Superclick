import ApplicationServices
import Foundation

struct Heading {
    let level: Int
    let text: String
}

/// Method A: ask the web area for the text between its start and end text markers.
/// One call, no tree walk. WebKit (Safari) supports this; Chromium mostly does too.
func textViaMarkers(_ web: AXUIElement) -> String? {
    guard let start = axAttr(web, "AXStartTextMarker"),
          let end = axAttr(web, "AXEndTextMarker"),
          let range = axParam(web, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
    else { return nil }
    return axParam(web, "AXStringForTextMarkerRange", range) as? String
}

/// The page's current selection, read through text markers (works when the
/// focused element is the page itself rather than a text field).
func selectionViaMarkers(_ web: AXUIElement) -> String? {
    guard let range = axAttr(web, "AXSelectedTextMarkerRange") else { return nil }
    return axParam(web, "AXStringForTextMarkerRange", range) as? String
}

/// Method B: walk the accessibility tree and collect static text, marking headings.
/// Slower, but works wherever text markers don't, and gives us the headings.
final class TreeWalker {
    private(set) var parts: [String] = []
    private(set) var headings: [Heading] = []
    private(set) var nodes = 0
    private(set) var truncated = false
    let nodeLimit: Int
    let deadline: Double

    init(nodeLimit: Int = 200_000, seconds: Double = 5) {
        self.nodeLimit = nodeLimit
        self.deadline = now() + seconds
    }

    private static let attrs = [
        kAXRoleAttribute as String,
        kAXValueAttribute as String,
        kAXTitleAttribute as String,
        kAXChildrenAttribute as String,
    ]

    func walk(_ root: AXUIElement) {
        visit(root, headingLevel: nil)
    }

    private var headingBuffer: [String] = []

    private func visit(_ el: AXUIElement, headingLevel: Int?) {
        if nodes >= nodeLimit || now() > deadline { truncated = true; return }
        nodes += 1

        let v = axMany(el, Self.attrs)
        let role = v[0] as? String ?? ""
        let kids = (v[3] as? [AXUIElement]) ?? []

        if role == "AXHeading" {
            // WebKit and Chromium report the heading level as the heading's AXValue.
            let level = (v[1] as? NSNumber)?.intValue ?? 0
            headingBuffer = []
            for k in kids { visit(k, headingLevel: level) }
            var text = headingBuffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, let title = v[2] as? String { text = title }
            if !text.isEmpty {
                headings.append(Heading(level: level, text: text))
                parts.append("\n\n" + String(repeating: "#", count: max(level, 1)) + " " + text + "\n\n")
            }
            return
        }

        if role == "AXStaticText", let s = v[1] as? String, !s.isEmpty {
            if headingLevel != nil { headingBuffer.append(s) } else { parts.append(s) }
        }

        for k in kids { visit(k, headingLevel: headingLevel) }

        // Paragraph-ish containers end a line, so the text doesn't run together.
        if headingLevel == nil, role == "AXGroup" || role == "AXParagraph" || role == "AXListItem" {
            if let last = parts.last, !last.hasSuffix("\n") { parts.append("\n") }
        }
    }

    var text: String {
        parts.joined(separator: " ")
            .replacingOccurrences(of: " \n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func wordCount(_ s: String) -> Int {
    s.split(whereSeparator: { $0.isWhitespace }).count
}

/// What we'd send by default: the headings, plus the text around the selection
/// (or the start of the page when nothing is selected).
func trimmed(full: String, selection: String?, headings: [Heading], window: Int = 1500) -> String {
    var out = ""
    if !headings.isEmpty {
        out += "Page outline:\n"
        for h in headings {
            out += String(repeating: "  ", count: max(h.level - 1, 0)) + "- " + h.text + "\n"
        }
        out += "\n"
    }
    let chars = Array(full)
    var lo = 0, hi = min(chars.count, window * 2)
    if let sel = selection, !sel.isEmpty, let r = full.range(of: sel) {
        let a = full.distance(from: full.startIndex, to: r.lowerBound)
        let b = full.distance(from: full.startIndex, to: r.upperBound)
        lo = max(0, a - window)
        hi = min(chars.count, b + window)
        out += "Text around the selection:\n"
    } else {
        out += "Start of the page:\n"
    }
    out += (lo > 0 ? "… " : "") + String(chars[lo..<hi]) + (hi < chars.count ? " …" : "")
    return out
}
