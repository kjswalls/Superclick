import Foundation

/// What we send by default instead of the full page (DECISIONS, 2026-11-04):
/// the page's headings as an outline, plus the text around the selection, or
/// the start of the page when nothing is selected.
public enum PageExcerpt {
    public static let defaultWindow = 1500

    public static func make(page: PageText, selection: String?, window: Int = defaultWindow) -> String {
        make(full: page.text, selection: selection, headings: page.headings, window: window)
    }

    public static func make(full: String, selection: String?, headings: [Heading], window: Int = defaultWindow) -> String {
        var out = ""
        if !headings.isEmpty {
            out += "Page outline:\n"
            for h in headings {
                out += String(repeating: "  ", count: max(h.level - 1, 0)) + "- " + h.text + "\n"
            }
            out += "\n"
        }
        let chars = Array(full)
        var lo = 0
        var hi = min(chars.count, window * 2)
        if let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty,
           let r = full.range(of: sel) {
            let a = full.distance(from: full.startIndex, to: r.lowerBound)
            let b = full.distance(from: full.startIndex, to: r.upperBound)
            lo = max(0, a - window)
            hi = min(chars.count, b + window)
            out += "Text around the selection:\n"
        } else {
            out += "Start of the page:\n"
        }
        if lo < hi {
            out += (lo > 0 ? "… " : "") + String(chars[lo..<hi]) + (hi < chars.count ? " …" : "")
        }
        return out
    }
}
