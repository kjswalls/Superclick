import AppKit
import ApplicationServices
import Foundation
import SuperclickCore

/// Reads a web page's full text, including what's scrolled off screen, from
/// the Accessibility tree. Grew out of the M1 page-text spike; the `pagetext`
/// tool runs the same code and prints a report.
public enum PageReader {
    public struct Options: Sendable {
        /// Fall back to AXEnhancedUserInterface for Chromium browsers that
        /// don't build their tree for AXManualAccessibility. It can upset window
        /// animations, so it's turned straight back off.
        public var allowEnhancedUI = true
        /// Time limit for the tree walk (it also collects the headings).
        public var walkSeconds = 1.5
        public var walkNodeLimit = 200_000
        /// Run the tree walk even when text markers worked (the check tool times both).
        public var alwaysWalk = true
        /// Breadth-first search limit when looking for the page. Native apps
        /// with no web view get a small one so a summon stays fast.
        public var searchLimit = 4000

        public init() {}
    }

    public struct Result: Sendable {
        public var url: String?
        public var windowTitle: String?
        /// The page's selection, read through text markers.
        public var selection: String?
        /// nil when no page was found.
        public var page: PageText?
        public var markerText: String?
        public var walkText: String?
        public var walkNodes = 0
        public var walkTruncated = false
        public var manualAXAccepted = false
        public var usedEnhancedUI = false
        public var coldStart = false
        public var locateMs = 0
        public var selectionMs = 0
        public var markerMs = 0
        public var walkMs = 0

        /// Time to the first full read: finding the page plus the faster method.
        public var fastestFullReadMs: Int {
            let marker = (markerText?.isEmpty == false) ? markerMs : Int.max
            return locateMs + min(marker, walkText == nil ? Int.max : walkMs)
        }
    }

    /// Browsers we know host a web area. Other apps are still searched, with a small limit.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "org.mozilla.firefox",
    ]

    public static func isChromium(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return !id.hasPrefix("com.apple.") && id != "org.mozilla.firefox"
    }

    /// Chromium and Electron apps only build their web accessibility tree when
    /// asked. AXManualAccessibility is the gentle switch. Safe to call on any app.
    @discardableResult
    public static func enableWebAccessibility(_ app: AXUIElement) -> Bool {
        axSetBool(app, "AXManualAccessibility", true) == .success
    }

    /// Reads the page in the app's focused window. Blocking: call it off the main thread.
    public static func read(pid: pid_t, bundleID: String?, options: Options = Options()) -> Result {
        var r = Result()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)

        let tStart = now()
        r.manualAXAccepted = enableWebAccessibility(app)

        func locate() -> (AXUIElement?, AXUIElement?) {
            let window = axElement(app, kAXFocusedWindowAttribute as String)
                ?? axElement(app, kAXMainWindowAttribute as String)
            guard let w = window else { return (nil, nil) }
            return (w, findFirst(role: "AXWebArea", under: w, limit: options.searchLimit))
        }

        var (foundWindow, foundWeb) = locate()
        let knownBrowser = bundleID.map { browsers.contains($0) } ?? false
        if knownBrowser, foundWeb == nil || (foundWeb.map { axChildren($0).isEmpty } ?? true) {
            // The first access to a Chromium tab can take a moment to populate.
            r.coldStart = true
            pump(seconds: 0.5)
            (foundWindow, foundWeb) = locate()
            if foundWeb == nil, options.allowEnhancedUI, isChromium(bundleID) {
                r.usedEnhancedUI = axSetBool(app, "AXEnhancedUserInterface", true) == .success
                pump(seconds: 1.0)
                (foundWindow, foundWeb) = locate()
            }
        }
        defer { if r.usedEnhancedUI { axSetBool(app, "AXEnhancedUserInterface", false) } }
        r.locateMs = elapsedMs(since: tStart)

        let window = foundWindow
        if let w = window { r.windowTitle = axString(w, kAXTitleAttribute as String) }
        guard let web = foundWeb else { return r }

        r.url = (axAttr(web, "AXURL") as? URL)?.absoluteString
            ?? window.flatMap { axString($0, kAXDocumentAttribute as String) }

        let tSel = now()
        r.selection = selectionViaMarkers(web)
        if r.selection?.isEmpty ?? true,
           let focused = axElement(app, kAXFocusedUIElementAttribute as String) {
            r.selection = axString(focused, kAXSelectedTextAttribute as String)
        }
        if r.selection?.isEmpty ?? false { r.selection = nil }
        r.selectionMs = elapsedMs(since: tSel)

        let tA = now()
        r.markerText = textViaMarkers(web)
        r.markerMs = elapsedMs(since: tA)
        let markersWorked = r.markerText?.isEmpty == false

        var headings: [Heading] = []
        if options.alwaysWalk || !markersWorked {
            let tB = now()
            let walker = TreeWalker(nodeLimit: options.walkNodeLimit, seconds: options.walkSeconds)
            walker.walk(web)
            r.walkText = walker.text
            r.walkMs = elapsedMs(since: tB)
            r.walkNodes = walker.nodes
            r.walkTruncated = walker.truncated
            headings = walker.headings
        }

        if markersWorked {
            r.page = PageText(text: r.markerText!, headings: headings, method: .textMarkers)
        } else if let t = r.walkText, !t.isEmpty {
            r.page = PageText(text: t, headings: headings, method: .treeWalk)
        }
        return r
    }

    /// Method A: ask the web area for the text between its start and end text markers.
    /// One call, no tree walk. WebKit (Safari) supports this; Chromium mostly does too.
    public static func textViaMarkers(_ web: AXUIElement) -> String? {
        guard let start = axAttr(web, "AXStartTextMarker"),
              let end = axAttr(web, "AXEndTextMarker"),
              let range = axParam(web, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
        else { return nil }
        return axParam(web, "AXStringForTextMarkerRange", range) as? String
    }

    /// The page's current selection, read through text markers (works when the
    /// focused element is the page itself rather than a text field).
    public static func selectionViaMarkers(_ web: AXUIElement) -> String? {
        guard let range = axAttr(web, "AXSelectedTextMarkerRange") else { return nil }
        return axParam(web, "AXStringForTextMarkerRange", range) as? String
    }
}

/// Method B: walk the accessibility tree and collect static text, marking headings.
/// Slower, but works wherever text markers don't, and gives us the headings.
public final class TreeWalker {
    public private(set) var parts: [String] = []
    public private(set) var headings: [Heading] = []
    public private(set) var nodes = 0
    public private(set) var truncated = false
    let nodeLimit: Int
    let deadline: Double

    public init(nodeLimit: Int = 200_000, seconds: Double = 5) {
        self.nodeLimit = nodeLimit
        self.deadline = now() + seconds
    }

    private static let attrs = [
        kAXRoleAttribute as String,
        kAXValueAttribute as String,
        kAXTitleAttribute as String,
        kAXChildrenAttribute as String,
    ]

    public func walk(_ root: AXUIElement) {
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

    public var text: String {
        parts.joined(separator: " ")
            .replacingOccurrences(of: " \n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
