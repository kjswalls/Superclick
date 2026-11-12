import Foundation

/// The app that was in front when you summoned.
public struct AppInfo: Codable, Sendable, Equatable {
    public var name: String
    public var bundleID: String?
    public var pid: Int32

    public init(name: String, bundleID: String?, pid: Int32) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }
}

public struct Heading: Codable, Sendable, Equatable {
    public var level: Int
    public var text: String

    public init(level: Int, text: String) {
        self.level = level
        self.text = text
    }
}

/// How the page text was read.
public enum PageMethod: String, Codable, Sendable {
    /// One call for everything between the page's start and end text markers.
    case textMarkers
    /// A walk of the accessibility tree.
    case treeWalk
}

/// A web page's full text, including what's scrolled off screen.
public struct PageText: Codable, Sendable, Equatable {
    public var text: String
    public var headings: [Heading]
    public var method: PageMethod
    public var wordCount: Int

    public init(text: String, headings: [Heading], method: PageMethod) {
        self.text = text
        self.headings = headings
        self.method = method
        self.wordCount = Words.count(text)
    }
}

/// One kind of captured item. Each one is a chip in the bubble and can be removed.
public enum ContextKind: String, Codable, Sendable, CaseIterable {
    case app, file, cwd, url, selection, page, screenshot
}

/// Everything captured at summon (SPEC: ContextBundle). Strings are already
/// redacted by the time they're stored here.
public struct ContextBundle: Codable, Sendable, Equatable {
    public var id: UUID
    public var capturedAt: Date
    public var app: AppInfo
    public var windowTitle: String?
    public var filePath: String?
    public var cwd: String?
    public var url: String?
    public var selection: String?
    public var page: PageText?
    public var screenshotPath: String?
    /// Redacted secrets by kind ("GitHub token": 1).
    public var redactions: [String: Int]
    /// Set when the app or site is on the blocklist, or looks like a private window.
    public var blockedReason: String?
    /// Milliseconds per capture step ("quick", "page", "screenshot", "visible").
    public var timings: [String: Int]
    /// Hashes of secrets already counted, so one secret in the selection and the
    /// page counts once. In memory only; never encoded.
    private var seenSecrets: Set<Int> = []

    enum CodingKeys: String, CodingKey {
        case id, capturedAt, app, windowTitle, filePath, cwd, url, selection, page, screenshotPath
        case redactions, blockedReason, timings
    }

    public init(app: AppInfo, id: UUID = UUID(), capturedAt: Date = Date()) {
        self.id = id
        self.capturedAt = capturedAt
        self.app = app
        self.redactions = [:]
        self.timings = [:]
    }

    public var redactionCount: Int { redactions.values.reduce(0, +) }

    public var isBlocked: Bool { blockedReason != nil }

    /// Drops everything except the app's name. Used when the app or site is blocklisted.
    public mutating func block(reason: String) {
        blockedReason = reason
        windowTitle = nil
        filePath = nil
        cwd = nil
        url = nil
        selection = nil
        page = nil
        screenshotPath = nil
        redactions = [:]
        seenSecrets = []
    }

    public mutating func remove(_ kind: ContextKind) {
        switch kind {
        case .app: windowTitle = nil
        case .file: filePath = nil
        case .cwd: cwd = nil
        case .url: url = nil
        case .selection: selection = nil
        case .page: page = nil
        case .screenshot: screenshotPath = nil
        }
    }

    /// Redacts and stores a captured string, adding what was found to `redactions`.
    public mutating func set(_ kind: ContextKind, _ value: String?, redactor: Redactor = .standard) {
        var clean: String? = nil
        if let v = value, !v.isEmpty {
            clean = redactor.redact(v, counts: &redactions, seen: &seenSecrets)
        }
        switch kind {
        case .app: windowTitle = clean
        case .file: filePath = clean
        case .cwd: cwd = clean
        case .url: url = clean
        case .selection: selection = clean
        case .page, .screenshot: break
        }
    }

    public mutating func setPage(_ page: PageText?, redactor: Redactor = .standard) {
        guard var p = page else { self.page = nil; return }
        p.text = redactor.redact(p.text, counts: &redactions, seen: &seenSecrets)
        var heads: [Heading] = []
        for h in p.headings {
            heads.append(Heading(level: h.level, text: redactor.redact(h.text, counts: &redactions, seen: &seenSecrets)))
        }
        p.headings = heads
        p.wordCount = Words.count(p.text)
        self.page = p
    }
}

public enum Words {
    public static func count(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    public static func lines(_ s: String) -> Int {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).count
    }

    /// "14 lines selected" for multi-line selections, "1 word selected" otherwise.
    public static func selectionLabel(_ s: String) -> String {
        let l = lines(s)
        if l > 1 { return "\(l) lines selected" }
        let w = count(s)
        return w == 1 ? "1 word selected" : "\(w) words selected"
    }
}
