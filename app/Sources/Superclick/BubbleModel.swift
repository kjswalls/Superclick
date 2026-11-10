import AppKit
import SuperclickCapture
import SuperclickCore

/// One chip in the bubble's context row.
struct Chip: Identifiable, Equatable {
    enum Kind: Equatable {
        case item(ContextKind)
        case secrets
        case blocked
        case pending(String)
    }

    var id: String
    var kind: Kind
    var label: String
    var symbol: String
    var tint: ChipTint
    var help: String?
    var removable: Bool
    /// The page chip toggles between the excerpt and the full page.
    var toggles = false
    var thumbnailPath: String?
    var appIconPID: Int32?

    var isPending: Bool {
        if case .pending = kind { return true }
        return false
    }
}

enum ChipTint {
    case neutral, blue, purple, green, orange, red, teal
}

enum LoadState: Equatable { case idle, loading, done }

/// Drives one summon: captures context in stages and holds what the bubble shows.
@MainActor
final class BubbleModel: ObservableObject {
    @Published private(set) var bundle: ContextBundle
    @Published private(set) var pageState: LoadState = .idle
    @Published private(set) var screenshotState: LoadState = .idle
    @Published var request = ""
    @Published var fullPage = false
    @Published var chipsExpanded = false
    @Published var status: String?
    /// Bumped to play the one-shot rainbow edge.
    @Published private(set) var glowToken = 0

    let summonedAt: Double
    private var removed: Set<ContextKind> = []
    private let settings: AppSettings
    private(set) var lastReport: CaptureReport

    init(app: NSRunningApplication, summonedAt: Double, settings: AppSettings) {
        self.summonedAt = summonedAt
        self.settings = settings
        let info = AppInfo(
            name: app.localizedName ?? "App", bundleID: app.bundleIdentifier, pid: app.processIdentifier)
        bundle = ContextBundle(app: info)
        lastReport = CaptureReport(appName: info.name, bundleID: info.bundleID)
    }

    var pid: pid_t { bundle.app.pid }

    // MARK: Capture

    /// Runs the capture stages. The bubble is already on screen with the app chip.
    func start(onReport: @escaping (CaptureReport) -> Void) {
        glowToken += 1
        let bundleID = bundle.app.bundleID
        let pid = self.pid
        let captureID = bundle.id

        if settings.blocklist.blocksApp(bundleID) {
            bundle.block(reason: "\(bundle.app.name) is on the blocklist")
            lastReport.blocked = bundle.blockedReason
            onReport(lastReport)
            return
        }
        guard Permissions.shared.accessibility else {
            status = "Superclick needs Accessibility permission to see what you're looking at."
            onReport(lastReport)
            return
        }

        pageState = .loading
        let isBrowser = bundleID.map { PageReader.browsers.contains($0) } ?? false
        let wantScreenshot = settings.captureScreenshot && Screenshot.hasPermission
        if wantScreenshot { screenshotState = .loading }

        Task.detached(priority: .userInitiated) {
            // Stage 1: title, file, selection.
            let quick = QuickContext.read(pid: pid, bundleID: bundleID)
            await self.applyQuick(quick)

            // Stage 2: the page. Browsers get the full search; other apps a quick look
            // for an embedded web view (Electron apps, help viewers).
            var options = PageReader.Options()
            options.alwaysWalk = true
            options.allowEnhancedUI = isBrowser
            if !isBrowser { options.searchLimit = 400; options.walkSeconds = 0.5 }
            let page = PageReader.read(pid: pid, bundleID: bundleID, options: options)
            let stillCapturing = await self.applyPage(page, isBrowser: isBrowser)

            // Stage 3: the screenshot, after the URL check so a blocked site never gets one.
            if wantScreenshot && stillCapturing {
                let t = now()
                let url = try? await Screenshot.captureFrontWindow(pid: pid, id: captureID)
                await self.applyScreenshot(url, ms: elapsedMs(since: t))
            } else {
                await self.applyScreenshot(nil, ms: 0)
            }
            await MainActor.run { onReport(self.lastReport) }
        }
    }

    private func applyQuick(_ q: QuickContext) {
        guard !bundle.isBlocked else { return }
        if !removed.contains(.app) { bundle.set(.app, q.windowTitle) }
        if !removed.contains(.file) { bundle.set(.file, q.filePath) }
        if !removed.contains(.cwd) { bundle.set(.cwd, q.cwd) }
        if !removed.contains(.selection) { bundle.set(.selection, q.selection) }
        bundle.timings["quick"] = q.ms
        lastReport.quickMs = q.ms
        lastReport.sinceHotkeyMs = elapsedMs(since: summonedAt)
        if Blocklist.looksPrivate(windowTitle: q.windowTitle) {
            bundle.block(reason: "this looks like a private window")
            lastReport.blocked = bundle.blockedReason
        }
    }

    /// Returns false when the page turned out to be blocked.
    private func applyPage(_ r: PageReader.Result, isBrowser: Bool) -> Bool {
        defer { pageState = .done }
        guard !bundle.isBlocked else { return false }
        if let site = settings.blocklist.blockedSite(for: r.url) {
            bundle.block(reason: "\(site) is on the blocklist")
            lastReport.blocked = bundle.blockedReason
            return false
        }
        if !removed.contains(.url) { bundle.set(.url, r.url) }
        if bundle.selection == nil, !removed.contains(.selection) { bundle.set(.selection, r.selection) }
        if !removed.contains(.page) { bundle.setPage(r.page) }
        if bundle.windowTitle == nil, !removed.contains(.app) { bundle.set(.app, r.windowTitle) }
        fullPage = settings.wantsFullPage(url: r.url)
        bundle.timings["page"] = r.fastestFullReadMs
        lastReport.page = r
        lastReport.pageSinceHotkeyMs = elapsedMs(since: summonedAt)
        lastReport.redactions = bundle.redactionCount
        return true
    }

    private func applyScreenshot(_ url: URL?, ms: Int) {
        screenshotState = .done
        guard let url else { return }
        if bundle.isBlocked || removed.contains(.screenshot) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        bundle.screenshotPath = url.path
        bundle.timings["screenshot"] = ms
        lastReport.screenshotMs = ms
    }

    func markVisible() {
        let t = elapsedMs(since: summonedAt)
        bundle.timings["visible"] = t
        lastReport.visibleMs = t
    }

    // MARK: Chips

    func remove(_ kind: ContextKind) {
        removed.insert(kind)
        if kind == .screenshot, let p = bundle.screenshotPath { try? FileManager.default.removeItem(atPath: p) }
        bundle.remove(kind)
    }

    var chips: [Chip] {
        var out: [Chip] = []
        let b = bundle
        out.append(Chip(
            id: "app", kind: .item(.app), label: b.app.name, symbol: "macwindow", tint: .neutral,
            help: b.windowTitle, removable: b.windowTitle != nil && !b.isBlocked, appIconPID: b.app.pid))

        if let reason = b.blockedReason {
            out.append(Chip(id: "blocked", kind: .blocked, label: "Not captured", symbol: "eye.slash",
                            tint: .orange, help: "Nothing was captured because \(reason).", removable: false))
            return out
        }
        if let f = b.filePath {
            out.append(Chip(id: "file", kind: .item(.file), label: Self.shortPath(f), symbol: "doc.text",
                            tint: .neutral, help: f, removable: true))
        }
        if let c = b.cwd {
            out.append(Chip(id: "cwd", kind: .item(.cwd), label: Self.shortPath(c), symbol: "terminal",
                            tint: .green, help: c, removable: true))
        }
        if let u = b.url {
            out.append(Chip(id: "url", kind: .item(.url), label: Self.shortURL(u), symbol: "link",
                            tint: .teal, help: u, removable: true))
        }
        if let s = b.selection {
            out.append(Chip(id: "selection", kind: .item(.selection), label: Words.selectionLabel(s),
                            symbol: "text.cursor", tint: .purple, help: String(s.prefix(400)), removable: true))
        }
        if let p = b.page {
            let label = fullPage ? "Full page · \(p.wordCount) words" : "Page text · around selection"
            out.append(Chip(
                id: "page", kind: .item(.page), label: label, symbol: "doc.richtext", tint: .blue,
                help: fullPage
                    ? "Sending the full page. Click to send only the outline and the text around the selection."
                    : "Sending the outline and the text around the selection. Click to send the full page (\(p.wordCount) words).",
                removable: true, toggles: true))
        } else if pageState == .loading {
            out.append(Chip(id: "page-pending", kind: .pending("Reading page…"), label: "Reading page…",
                            symbol: "doc.richtext", tint: .neutral, removable: false))
        }
        if let s = b.screenshotPath {
            out.append(Chip(id: "screenshot", kind: .item(.screenshot), label: "Screenshot", symbol: "camera.viewfinder",
                            tint: .neutral, help: s, removable: true, thumbnailPath: s))
        } else if screenshotState == .loading {
            out.append(Chip(id: "screenshot-pending", kind: .pending("Screenshot…"), label: "Screenshot…",
                            symbol: "camera.viewfinder", tint: .neutral, removable: false))
        }
        if b.redactionCount > 0 {
            let n = b.redactionCount
            let kinds = b.redactions.keys.sorted().joined(separator: ", ")
            out.append(Chip(id: "secrets", kind: .secrets, label: "\(n) secret\(n == 1 ? "" : "s") redacted",
                            symbol: "lock.fill", tint: .orange, help: "Replaced before sending: \(kinds)", removable: false))
        }
        return out
    }

    static func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var s = p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        let parts = s.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count > 3 { s = "…/" + parts.suffix(2).joined(separator: "/") }
        return s
    }

    static func shortURL(_ u: String) -> String {
        guard let c = URLComponents(string: u), let host = c.host else { return u }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = c.path == "/" ? "" : c.path
        let s = h + path
        return s.count > 42 ? String(s.prefix(41)) + "…" : s
    }

    // MARK: Sending

    var promptText: String {
        PromptText.render(request: request, bundle: bundle, fullPage: fullPage)
    }
}

/// What the Diagnostics window shows about the last summon. This is the
/// page-text spike, built into the app.
struct CaptureReport {
    var appName: String
    var bundleID: String?
    var at = Date()
    var visibleMs: Int?
    var quickMs: Int?
    var sinceHotkeyMs: Int?
    var pageSinceHotkeyMs: Int?
    var screenshotMs: Int?
    var redactions = 0
    var blocked: String?
    var page: PageReader.Result?
}
