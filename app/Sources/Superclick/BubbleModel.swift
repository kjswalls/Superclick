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

enum ReplyPhase: Equatable { case none, waiting, streaming, done, failed }

struct PendingApproval: Equatable, Identifiable {
    var id: String
    var tool: String
    var summary: String
    /// The full input: the whole command, or the content being written.
    var detail: String
}

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

    // The agent's reply (M2).
    @Published private(set) var phase: ReplyPhase = .none
    @Published private(set) var replyText = ""
    @Published private(set) var finalText: String?
    @Published private(set) var toolLines: [String] = []
    /// Approvals waiting for an answer, oldest first. The card shows the first.
    @Published private(set) var approvals: [PendingApproval] = []
    @Published var approvalReply = ""
    // Where the coordinator sent it (M3).
    @Published private(set) var route: RouteInfo?
    /// Set once the user has answered "shop or Inbox?" or moved the request.
    @Published private(set) var routeSettled = false
    @Published var showMove = false
    @Published var moveName = ""
    /// When the request was sent and when it finished, for the menu and the catch-up cards.
    private(set) var sentAt: Date?
    private(set) var finishedAt: Date?
    /// The request currently with the agent.
    private(set) var requestID: String?
    /// The question this reply answers, kept for "Show last answer".
    private(set) var askedText = ""
    /// Whether the user has seen the finished answer (clears the menu-bar badge).
    var seen = false
    /// Called when something changes while the bubble is closed (answer ready, approval needed).
    var onBackgroundChange: (() -> Void)?
    /// Called for the moments worth a notification: a new approval, or the turn finishing.
    var onNotable: ((BubbleModel, Notable) -> Void)?

    enum Notable {
        case approval(PendingApproval)
        case finished
    }

    let summonedAt: Double
    /// Set when the bubble closes: late capture stages stop and clean up after themselves.
    private(set) var closed = false
    /// True once every capture stage has finished (or been skipped).
    @Published private(set) var captureFinished = false
    private var onCaptured: [() -> Void] = []
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

    /// A bubble for a request the daemon is running that this app didn't start
    /// (it was restarted mid-request). There's no capture; the reply is what matters.
    init(restoring snap: RunSnapshot, settings: AppSettings) {
        summonedAt = now()
        self.settings = settings
        let info = AppInfo(name: snap.route?.project ?? "Superclick", bundleID: nil, pid: 0)
        bundle = ContextBundle(app: info)
        lastReport = CaptureReport(appName: info.name, bundleID: nil)
        captureFinished = true
        closed = true
        requestID = snap.id
        askedText = snap.asked
        sentAt = Date()
        apply(.resync(snap))
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
            finishCapture()
            onReport(lastReport)
            return
        }
        guard Permissions.shared.accessibility else {
            status = "Superclick needs Accessibility permission to see what you're looking at."
            finishCapture()
            onReport(lastReport)
            return
        }

        pageState = .loading
        let isBrowser = bundleID.map { PageReader.browsers.contains($0) } ?? false
        let wantScreenshot = settings.captureScreenshot && Screenshot.hasPermission
        if wantScreenshot { screenshotState = .loading }

        Task.detached(priority: .userInitiated) {
            Screenshot.clearOld()

            // Stage 1: title, file, selection.
            let quick = QuickContext.read(pid: pid, bundleID: bundleID)
            await self.applyQuick(quick)
            if await self.closed { await self.finishCapture(); return }

            // Stage 2: the page. Browsers get the full search; other apps a quick look
            // for an embedded web view (Electron apps, help viewers). The tree walk
            // is only for headings once text markers worked, so it gets a short limit.
            var options = PageReader.Options()
            options.alwaysWalk = true
            options.allowEnhancedUI = isBrowser
            options.walkSeconds = isBrowser ? 0.6 : 0.4
            if !isBrowser { options.searchLimit = 400 }
            let page = PageReader.read(pid: pid, bundleID: bundleID, options: options)
            let stillCapturing = await self.applyPage(page, isBrowser: isBrowser)

            // Stage 3: the screenshot, after the URL check so a blocked site never gets one.
            if wantScreenshot && stillCapturing, !(await self.closed) {
                let t = now()
                let url = try? await Screenshot.captureFrontWindow(pid: pid, id: captureID)
                await self.applyScreenshot(url, ms: elapsedMs(since: t))
            } else {
                await self.applyScreenshot(nil, ms: 0)
            }
            await self.finishCapture()
            await MainActor.run { onReport(self.lastReport) }
        }
    }

    private func finishCapture() {
        guard !captureFinished else { return }
        captureFinished = true
        let waiting = onCaptured
        onCaptured = []
        for f in waiting { f() }
    }

    /// Runs `f` once every capture stage is done, so nothing is sent before the
    /// blocklist has seen the page's URL.
    func whenCaptured(_ f: @escaping () -> Void) {
        if captureFinished { f() } else { onCaptured.append(f) }
    }

    /// The bubble closed. Unsent screenshots are deleted.
    func markClosed(keepScreenshot: Bool) {
        closed = true
        if !keepScreenshot, let p = bundle.screenshotPath {
            try? FileManager.default.removeItem(atPath: p)
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

    /// Returns false when the page turned out to be blocked, or a screenshot
    /// shouldn't be taken.
    private func applyPage(_ r: PageReader.Result, isBrowser: Bool) -> Bool {
        defer { pageState = .done }
        guard !bundle.isBlocked else { return false }
        if let site = settings.blocklist.blockedSite(for: r.url) {
            bundle.block(reason: "\(site) is on the blocklist")
            lastReport.blocked = bundle.blockedReason
            return false
        }
        if Blocklist.looksPrivate(windowTitle: r.windowTitle) {
            bundle.block(reason: "this looks like a private window")
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
        // A browser page whose URL couldn't be read can't be checked against the
        // blocklist, so it gets no screenshot.
        if isBrowser && r.url == nil { return false }
        return true
    }

    private func applyScreenshot(_ url: URL?, ms: Int) {
        screenshotState = .done
        guard let url else { return }
        if bundle.isBlocked || removed.contains(.screenshot) || closed {
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

    var isBusy: Bool { phase == .waiting || phase == .streaming }

    /// What Paste here and Copy use: the final answer, or what has streamed so far.
    var answerText: String { finalText ?? replyText }

    var approval: PendingApproval? { approvals.first }
    var routeLabel: String? { route.map { "→ \($0.project)" } }
    var routeReason: String? { route?.reason }
    var projectName: String { route?.project ?? "Claude Code" }

    /// Low confidence: the bubble asks "shop or Inbox?" until the user picks.
    var needsRouteChoice: Bool {
        guard let r = route, !routeSettled else { return false }
        return r.step == "fallback" && !r.ask.isEmpty
    }

    func beginRequest(id: String, text: String) {
        requestID = id
        askedText = text
        sentAt = Date()
        finishedAt = nil
        seen = false
        route = nil
        routeSettled = false
        resetReply()
        status = nil
        request = ""
    }

    /// The request is being moved to another project; its new run starts over.
    func beginMove() {
        routeSettled = true
        showMove = false
        moveName = ""
        resetReply()
        status = "Moving…"
    }

    func settleRoute() { routeSettled = true }

    private func resetReply() {
        phase = .waiting
        replyText = ""
        finalText = nil
        toolLines = []
        approvals = []
        approvalReply = ""
        finishedAt = nil
    }

    private func pushTool(_ line: String) {
        toolLines.append(line)
        if toolLines.count > 4 { toolLines.removeFirst(toolLines.count - 4) }
    }

    func apply(_ event: ReplyEvent) {
        switch event {
        case .accepted(let route, let note):
            // The first event of every run, including a moved one.
            resetReply()
            if let route {
                if self.route != nil && self.route?.projectID != route.projectID { routeSettled = true }
                self.route = route
                status = nil
            } else {
                status = note
            }
        case .delta(let text):
            phase = .streaming
            replyText += text
        case .tool(let summary):
            pushTool(summary)
        case .approval(let id, let tool, let summary, let detail):
            if !approvals.contains(where: { $0.id == id }) {
                let a = PendingApproval(id: id, tool: tool, summary: summary, detail: detail)
                approvals.append(a)
                onNotable?(self, .approval(a))
            }
            onBackgroundChange?()
        case .approvalExpired(let id):
            approvals.removeAll { $0.id == id }
            status = "That approval had expired, so Claude Code was told no."
            onBackgroundChange?()
        case .resync(let snap):
            if let r = snap.route { route = r }
            replyText = snap.text
            toolLines = Array(snap.tools.suffix(4))
            approvals = snap.approvals
            switch snap.status {
            case "done":
                finalText = snap.final ?? snap.text
                if replyText.isEmpty { replyText = finalText ?? "" }
                phase = .done
                finishedAt = finishedAt ?? Date()
            case "failed":
                phase = .failed
                status = snap.error
                finishedAt = finishedAt ?? Date()
            default:
                phase = snap.text.isEmpty ? .waiting : .streaming
            }
            onBackgroundChange?()
        case .done(let text):
            finalText = text.isEmpty ? replyText : text
            if replyText.isEmpty { replyText = text }
            phase = .done
            approvals = []
            finishedAt = Date()
            onNotable?(self, .finished)
            onBackgroundChange?()
        case .error(let message):
            phase = .failed
            approvals = []
            status = message
            finishedAt = Date()
            // A stop the user asked for isn't news.
            if message != "Cancelled." { onNotable?(self, .finished) }
            onBackgroundChange?()
        }
    }

    /// Takes an answered approval off the card; the next one, if any, shows.
    func clearApproval(id: String) {
        approvals.removeAll { $0.id == id }
        approvalReply = ""
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
