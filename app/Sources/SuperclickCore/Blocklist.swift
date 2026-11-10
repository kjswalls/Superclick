import Foundation

/// Apps and sites that are never captured (SPEC: Privacy and safety). When one
/// is in front, the bubble still opens, but only the app's name is kept and a
/// "not captured" chip says why.
public struct Blocklist: Codable, Sendable, Equatable {
    /// Bundle identifiers.
    public var apps: [String]
    /// Domains. A domain also blocks its subdomains ("chase.com" blocks "secure.chase.com").
    public var sites: [String]

    public init(apps: [String], sites: [String]) {
        self.apps = apps
        self.sites = sites
    }

    public static let defaultApps = [
        "com.1password.1password",       // 1Password 8
        "com.agilebits.onepassword7",    // 1Password 7
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "org.keepassxc.keepassxc",
    ]

    public static let defaultSites = [
        "1password.com",
        "bitwarden.com",
        "lastpass.com",
        "accounts.google.com",
        "appleid.apple.com",
        "paypal.com",
        "chase.com",
        "bankofamerica.com",
        "wellsfargo.com",
        "citi.com",
        "capitalone.com",
        "americanexpress.com",
        "schwab.com",
        "fidelity.com",
        "vanguard.com",
    ]

    public static let standard = Blocklist(apps: defaultApps, sites: defaultSites)

    public func blocksApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return apps.contains { $0.lowercased() == id }
    }

    /// The blocklisted domain that matches `url`, if any.
    public func blockedSite(for url: String?) -> String? {
        guard let url, let host = Domain.host(of: url) else { return nil }
        return sites.first { Domain.matches(host: host, domain: $0) }
    }

    /// Private browsing can't be detected reliably through Accessibility, so
    /// this only catches windows whose title says so (Firefox, some Chromium
    /// browsers). Safari private windows are a known gap (see DECISIONS.md).
    public static func looksPrivate(windowTitle: String?) -> Bool {
        guard let t = windowTitle?.lowercased() else { return false }
        return t.contains("private browsing") || t.contains("(incognito)") || t.hasSuffix("incognito")
            || t.contains("inprivate")
    }
}

public enum Domain {
    /// Lowercased host without "www.", or nil when `url` has none.
    public static func host(of url: String) -> String? {
        let withScheme = url.contains("://") ? url : "https://" + url
        guard let h = URLComponents(string: withScheme)?.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Normalizes what someone typed in settings: "https://www.Chase.com/login" or "*.chase.com" → "chase.com".
    public static func normalize(_ typed: String) -> String? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("*.") { s = String(s.dropFirst(2)) }
        if s.hasPrefix(".") { s = String(s.dropFirst()) }
        guard !s.isEmpty else { return nil }
        return host(of: s)
    }

    public static func matches(host: String, domain: String) -> Bool {
        guard let d = normalize(domain) else { return false }
        let h = host.lowercased()
        return h == d || h.hasSuffix("." + d)
    }
}
