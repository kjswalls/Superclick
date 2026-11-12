import AppKit
import SuperclickCapture
import SuperclickCore
import SwiftUI

/// The page-text spike, built in: what the last summon captured and how long
/// each step took, against M1's 300 ms target.
struct DiagnosticsView: View {
    @ObservedObject var store: DiagnosticsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Summon over a long article in Safari or Chrome (don't scroll down), then come back here. The `pagetext` tool in the repo runs the same check from Terminal.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = store.last {
                    report(r)
                } else {
                    Text("Nothing captured yet.").font(.headline)
                }
            }
            .padding(24)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    @ViewBuilder
    private func report(_ r: CaptureReport) -> some View {
        let page = r.page
        let visible = r.visibleMs ?? 0
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("App", "\(r.appName) (\(r.bundleID ?? "?"))")
            row("Captured", r.at.formatted(date: .omitted, time: .standard))
            if let b = r.blocked { row("Blocked", b) }
            row("Bubble shown", "\(visible) ms after the hotkey", pass: visible < 300)
            if let q = r.quickMs, let since = r.sinceHotkeyMs {
                row("Title + selection", "\(q) ms (ready \(since) ms after the hotkey)", pass: since < 300)
            }
            if let p = page {
                row("URL", p.url ?? "none")
                row("Setup", [p.manualAXAccepted ? "AXManualAccessibility accepted" : "AXManualAccessibility not supported",
                              p.usedEnhancedUI ? "needed AXEnhancedUserInterface" : nil,
                              p.coldStart ? "cold start" : nil].compactMap { $0 }.joined(separator: ", "))
                row("Find page", "\(p.locateMs) ms")
                row("Text markers", markerSummary(p))
                row("Tree walk", "\(Words.count(p.walkText ?? "")) words in \(p.walkMs) ms, \(p.walkNodes) nodes\(p.walkTruncated ? ", stopped early" : "")")
                row("Headings", "\(p.page?.headings.count ?? 0)")
                if p.page != nil {
                    row("Full read", "\(p.fastestFullReadMs) ms", pass: p.fastestFullReadMs < 300)
                }
                if let since = r.pageSinceHotkeyMs { row("Page ready", "\(since) ms after the hotkey") }
            } else if r.blocked == nil {
                row("Page", "No web page in this window")
            }
            if let s = r.screenshotMs { row("Screenshot", "\(s) ms") }
            row("Secrets", "\(r.redactions) redacted")
        }

        if let text = page?.page?.text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Starts with").font(.headline)
                Text(String(text.prefix(240))).textSelection(.enabled).foregroundStyle(.secondary)
                Text("Ends with").font(.headline)
                Text(String(text.suffix(240))).textSelection(.enabled).foregroundStyle(.secondary)
                Text("Off-screen passes when \u{201C}Ends with\u{201D} matches the article's last lines, even though you never scrolled there.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save full text…") { save(text, name: "pagetext-full.txt") }
                    Button("Copy report") { copyReport(r) }
                }
                .padding(.top, 4)
            }
        }
    }

    private func markerSummary(_ p: PageReader.Result) -> String {
        if let t = p.markerText, !t.isEmpty { return "\(Words.count(t)) words in \(p.markerMs) ms" }
        return "not supported (\(p.markerMs) ms)"
    }

    private func row(_ label: String, _ value: String, pass: Bool? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let pass {
                    Text(pass ? "PASS" : "SLOW")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((pass ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                }
                Text(value).textSelection(.enabled)
            }
        }
    }

    private func save(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func copyReport(_ r: CaptureReport) {
        var lines = ["Superclick page-text check", "App: \(r.appName) (\(r.bundleID ?? "?"))",
                     "Bubble shown: \(r.visibleMs ?? 0) ms", "Title + selection ready: \(r.sinceHotkeyMs ?? 0) ms"]
        if let p = r.page {
            lines += ["URL: \(p.url ?? "none")",
                      "Find page: \(p.locateMs) ms",
                      "Text markers: \(p.markerText.map { "\(Words.count($0)) words" } ?? "not supported") in \(p.markerMs) ms",
                      "Tree walk: \(Words.count(p.walkText ?? "")) words in \(p.walkMs) ms",
                      "Full read: \(p.fastestFullReadMs) ms",
                      "Ends with: \(String((p.page?.text ?? "").suffix(160)).replacingOccurrences(of: "\n", with: " "))"]
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
