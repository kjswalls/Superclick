import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures the front window of an app with ScreenCaptureKit. Needs Screen
/// Recording permission; without it, nothing is captured and the bubble says so.
public enum Screenshot {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures go here and are cleared after a day.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Superclick/Captures", isDirectory: true)
    }

    /// The app's frontmost normal window, in front-to-back order from the window server.
    public static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? UInt32 else { continue }
            if let b = info[kCGWindowBounds as String] as? [String: Any],
               let w = b["Width"] as? Double, let h = b["Height"] as? Double, w < 80 || h < 80 {
                continue
            }
            return CGWindowID(id)
        }
        return nil
    }

    /// Saves a PNG of the app's front window and returns its path.
    public static func captureFrontWindow(pid: pid_t, id: UUID) async throws -> URL? {
        guard hasPermission, let windowID = frontWindowID(pid: pid) else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id.uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    /// Deletes captures older than `age` seconds.
    public static func clearOld(olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
