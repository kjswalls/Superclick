import AppKit
import ApplicationServices
import Foundation

/// The cheap part of a capture, read straight after the hotkey: window title,
/// the document or folder the window represents, and the selected text.
/// A handful of Accessibility calls with a short timeout.
public struct QuickContext: Sendable {
    public var windowTitle: String?
    /// A file path for document windows (Xcode, TextEdit, Preview…).
    public var filePath: String?
    /// A folder for terminal windows (Terminal and iTerm set the window's folder).
    public var cwd: String?
    public var selection: String?
    public var focusedRole: String?
    public var ms = 0

    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty",
    ]

    /// Blocking; call it off the main thread.
    public static func read(pid: pid_t, bundleID: String?, timeout: Float = 0.25) -> QuickContext {
        let t0 = now()
        var q = QuickContext()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)

        let window = axElement(app, kAXFocusedWindowAttribute as String)
            ?? axElement(app, kAXMainWindowAttribute as String)
        if let w = window {
            q.windowTitle = axString(w, kAXTitleAttribute as String).flatMap { $0.isEmpty ? nil : $0 }
            if let doc = axString(w, kAXDocumentAttribute as String), let path = Self.path(fromDocument: doc) {
                let isDir = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir || terminals.contains(bundleID ?? "") {
                    q.cwd = path
                } else {
                    q.filePath = path
                }
            }
        }

        if let focused = axElement(app, kAXFocusedUIElementAttribute as String) {
            q.focusedRole = axString(focused, kAXRoleAttribute as String)
            if let sel = axString(focused, kAXSelectedTextAttribute as String),
               !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                q.selection = sel
            }
        }
        q.ms = ms(since: t0)
        return q
    }

    /// AXDocument is usually a file URL string; some apps give a plain path.
    static func path(fromDocument doc: String) -> String? {
        if doc.hasPrefix("file://") { return URL(string: doc)?.path }
        if doc.hasPrefix("/") { return doc }
        return nil
    }
}
