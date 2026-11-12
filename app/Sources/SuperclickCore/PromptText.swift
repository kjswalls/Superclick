import Foundation

/// Renders a request and its context as Markdown. In M1 this is what Enter
/// copies to the clipboard, so the bubble is useful before agents arrive in M2;
/// from M2 the same text is what the Claude Code adapter receives.
public enum PromptText {
    public static func render(request: String, bundle: ContextBundle, fullPage: Bool) -> String {
        var out = request.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []

        if let reason = bundle.blockedReason {
            lines.append("- App: \(bundle.app.name) (not captured: \(reason))")
        } else {
            var app = "- App: \(bundle.app.name)"
            if let t = bundle.windowTitle { app += " — \u{201C}\(t)\u{201D}" }
            lines.append(app)
            if let u = bundle.url { lines.append("- URL: \(u)") }
            if let f = bundle.filePath { lines.append("- File: \(f)") }
            if let c = bundle.cwd { lines.append("- Working directory: \(c)") }
            if let s = bundle.screenshotPath { lines.append("- Screenshot: \(s)") }
            if let s = bundle.selection {
                lines.append("- Selected text:")
                lines.append(fenced(s))
            }
            if let p = bundle.page {
                if fullPage {
                    lines.append("- Full page text (\(p.wordCount) words):")
                    lines.append(fenced(p.text))
                } else {
                    lines.append("- Page text (outline and the part around the selection; \(p.wordCount) words in all):")
                    lines.append(fenced(PageExcerpt.make(page: p, selection: bundle.selection)))
                }
            }
            if bundle.redactionCount > 0 {
                let n = bundle.redactionCount
                lines.append("- \(n) secret\(n == 1 ? "" : "s") redacted before sending.")
            }
        }

        out += "\n\n---\nContext captured by Superclick:\n" + lines.joined(separator: "\n")
        return out
    }

    /// A fence longer than any run of backticks inside `text`.
    static func fenced(_ text: String) -> String {
        var longest = 0, run = 0
        for ch in text {
            if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + text + "\n" + fence
    }
}
