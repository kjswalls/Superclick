import Foundation

/// Global shortcuts offered in Settings. ⌥Space is the default, but Raycast,
/// Alfred and some input methods also like it, so there are alternatives.
public enum HotkeyPreset: String, Codable, Sendable, CaseIterable {
    case optionSpace
    case controlOptionSpace
    case shiftOptionSpace
    case commandShiftSpace

    public var label: String {
        switch self {
        case .optionSpace: return "⌥Space"
        case .controlOptionSpace: return "⌃⌥Space"
        case .shiftOptionSpace: return "⇧⌥Space"
        case .commandShiftSpace: return "⇧⌘Space"
        }
    }
}

/// User settings, stored as JSON in UserDefaults by the app. Every field has a
/// default, so settings saved by an older build still load.
public struct AppSettings: Codable, Sendable, Equatable {
    public var hotkey: HotkeyPreset = .optionSpace
    /// Send the full page text instead of the excerpt around the selection.
    public var fullPageByDefault = false
    /// Sites that always get the full page, whatever the global setting.
    public var fullPageSites: [String] = []
    public var captureScreenshot = true
    public var blocklist = Blocklist.standard
    public var onboardingDone = false
    /// macOS notifications when a closed bubble's answer is ready or needs an OK (M4).
    public var notifyWhenDone = true
    public var notifyForApprovals = true
    /// When the "while you were away" cards were last opened (seconds since 1970).
    public var catchUpSeenAt: Double = 0

    public init() {}

    public func wantsFullPage(url: String?) -> Bool {
        if fullPageByDefault { return true }
        guard let url, let host = Domain.host(of: url) else { return false }
        return fullPageSites.contains { Domain.matches(host: host, domain: $0) }
    }

    enum CodingKeys: String, CodingKey {
        case hotkey, fullPageByDefault, fullPageSites, captureScreenshot, blocklist, onboardingDone
        case notifyWhenDone, notifyForApprovals, catchUpSeenAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        hotkey = (try? c.decodeIfPresent(HotkeyPreset.self, forKey: .hotkey)) ?? d.hotkey
        fullPageByDefault = (try? c.decodeIfPresent(Bool.self, forKey: .fullPageByDefault)) ?? d.fullPageByDefault
        fullPageSites = (try? c.decodeIfPresent([String].self, forKey: .fullPageSites)) ?? d.fullPageSites
        captureScreenshot = (try? c.decodeIfPresent(Bool.self, forKey: .captureScreenshot)) ?? d.captureScreenshot
        blocklist = (try? c.decodeIfPresent(Blocklist.self, forKey: .blocklist)) ?? d.blocklist
        onboardingDone = (try? c.decodeIfPresent(Bool.self, forKey: .onboardingDone)) ?? d.onboardingDone
        notifyWhenDone = (try? c.decodeIfPresent(Bool.self, forKey: .notifyWhenDone)) ?? d.notifyWhenDone
        notifyForApprovals = (try? c.decodeIfPresent(Bool.self, forKey: .notifyForApprovals)) ?? d.notifyForApprovals
        catchUpSeenAt = (try? c.decodeIfPresent(Double.self, forKey: .catchUpSeenAt)) ?? d.catchUpSeenAt
    }
}
