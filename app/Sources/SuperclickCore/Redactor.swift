import Foundation

/// Replaces obvious secrets (API keys, tokens, private keys, passwords in
/// assignments or URLs) with a visible placeholder before anything is shown
/// or sent. The bubble shows the count as its own chip, so redaction is never
/// silent (DECISIONS: "Secret redaction is visible").
public final class Redactor: @unchecked Sendable {
    public struct Rule {
        public let kind: String
        let regex: NSRegularExpression
        /// Capture group holding the secret. 0 replaces the whole match.
        let group: Int

        init(_ kind: String, _ pattern: String, group: Int = 0, caseInsensitive: Bool = false) {
            self.kind = kind
            // Patterns are constants; a bad one is a programming error caught by the tests.
            self.regex = try! NSRegularExpression(
                pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            self.group = group
        }
    }

    public let rules: [Rule]

    public init(rules: [Rule]) { self.rules = rules }

    /// Ordered from most to least specific, so a GitHub token is reported as
    /// one rather than as a generic "token = …" assignment.
    public static let standard = Redactor(rules: [
        Rule("private key",
             "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
        Rule("Anthropic key", "\\bsk-ant-[A-Za-z0-9_\\-]{20,}"),
        Rule("OpenAI key", "\\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_\\-]{20,}"),
        Rule("GitHub token", "\\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\\b"),
        Rule("GitHub token", "\\bgithub_pat_[A-Za-z0-9_]{22,}"),
        Rule("AWS key", "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"),
        Rule("Slack token", "\\bxox[abprs]-[A-Za-z0-9\\-]{10,}"),
        Rule("Stripe key", "\\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"),
        Rule("Google API key", "\\bAIza[0-9A-Za-z_\\-]{35}"),
        Rule("JWT", "\\beyJ[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}"),
        Rule("bearer token", "\\bbearer\\s+([A-Za-z0-9._~+/\\-]{20,}=*)", group: 1, caseInsensitive: true),
        Rule("secret in URL",
             "[?&](?:token|access_token|refresh_token|api_key|apikey|key|secret|password|sig|signature)=([^&#\\s\\[][^&#\\s]{7,})",
             group: 1, caseInsensitive: true),
        Rule("password or key",
             "\\b[A-Za-z0-9_]*?(?:api[_\\-]?key|secret[_\\-]?key|client[_\\-]?secret|secret|token|auth[_\\-]?token|password|passwd|pwd|access[_\\-]?key)\\b[\"']?\\s*[:=]\\s*[\"']?([^\\s\"',;\\[][^\\s\"',;]{5,})",
             group: 1, caseInsensitive: true),
    ])

    public static func placeholder(_ kind: String) -> String { "[redacted \(kind)]" }

    /// Returns `text` with secrets replaced, and adds what it found to `counts`.
    public func redact(_ text: String, counts: inout [String: Int]) -> String {
        var seen = Set<Int>()
        return redact(text, counts: &counts, seen: &seen)
    }

    /// Like `redact(_:counts:)`, but a secret already in `seen` (from another
    /// field of the same capture) is replaced without being counted again.
    public func redact(_ text: String, counts: inout [String: Int], seen: inout Set<Int>) -> String {
        var out = text
        for rule in rules {
            let ns = out as NSString
            let matches = rule.regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            let mutable = NSMutableString(string: out)
            var found = 0
            for m in matches.reversed() {
                let r = m.range(at: rule.group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                let secret = ns.substring(with: r)
                mutable.replaceCharacters(in: r, with: Self.placeholder(rule.kind))
                if seen.insert(secret.hashValue).inserted { found += 1 }
            }
            if found > 0 { counts[rule.kind, default: 0] += found }
            out = mutable as String
        }
        return out
    }

    public func redact(_ text: String) -> String {
        var ignored: [String: Int] = [:]
        return redact(text, counts: &ignored)
    }
}
