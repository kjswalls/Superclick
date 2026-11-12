import XCTest
@testable import SuperclickCore

final class RedactorTests: XCTestCase {
    func redact(_ s: String) -> (String, [String: Int]) {
        var counts: [String: Int] = [:]
        let out = Redactor.standard.redact(s, counts: &counts)
        return (out, counts)
    }

    func testKnownTokenShapes() {
        let cases: [(String, String)] = [
            ("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123", "Anthropic key"),
            ("OPENAI=sk-proj-abcdefghijklmnopqrstuvwx", "OpenAI key"),
            ("ghp_" + String(repeating: "a", count: 36), "GitHub token"),
            ("github_pat_11ABCDEFG0123456789_abcdefghijklmnop", "GitHub token"),
            ("AKIAIOSFODNN7EXAMPLE", "AWS key"),
            ("xoxb-1234567890-abcdefghij", "Slack token"),
            ("sk_live_" + String(repeating: "x", count: 24), "Stripe key"),
            ("AIza" + String(repeating: "B", count: 35), "Google API key"),
            // Assembled at run time from fake parts, so secret scanners don't flag the fixture.
            (["eyJ" + String(repeating: "a", count: 16), String(repeating: "b", count: 16), String(repeating: "c", count: 16)]
                .joined(separator: "."), "JWT"),
        ]
        for (input, kind) in cases {
            let (out, counts) = redact(input)
            XCTAssertEqual(counts[kind], 1, "\(input) should count as \(kind), got \(counts)")
            XCTAssertTrue(out.contains(Redactor.placeholder(kind)), out)
        }
    }

    func testOnlyTheSecretPartIsReplaced() {
        let (out, counts) = redact("curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456' x")
        XCTAssertEqual(out, "curl -H 'Authorization: Bearer [redacted bearer token]' x")
        XCTAssertEqual(counts, ["bearer token": 1])

        let (url, _) = redact("https://example.com/cb?code=1&access_token=abcdef123456&x=2")
        XCTAssertEqual(url, "https://example.com/cb?code=1&access_token=[redacted secret in URL]&x=2")

        let (env, _) = redact("DB_PASSWORD=hunter2hunter2\nPORT=5432")
        XCTAssertEqual(env, "DB_PASSWORD=[redacted password or key]\nPORT=5432")
    }

    func testPrivateKeyBlock() {
        let pem = "a\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----\nb"
        let (out, counts) = redact(pem)
        XCTAssertEqual(out, "a\n[redacted private key]\nb")
        XCTAssertEqual(counts["private key"], 1)
    }

    func testSpecificRuleWinsAndIsNotDoubleCounted() {
        let (out, counts) = redact("token: ghp_" + String(repeating: "Z", count: 36))
        XCTAssertEqual(out, "token: [redacted GitHub token]")
        XCTAssertEqual(counts, ["GitHub token": 1])
    }

    func testURLSecretIsNotRedactedTwice() {
        let (out, counts) = redact("https://x.example/cb?token=ghp_" + String(repeating: "k", count: 36))
        XCTAssertEqual(out, "https://x.example/cb?token=[redacted GitHub token]")
        XCTAssertEqual(counts, ["GitHub token": 1])
    }

    func testShortPasswords() {
        let (out, _) = redact("password: hunter2")
        XCTAssertEqual(out, "password: [redacted password or key]")
    }

    func testOrdinaryTextIsUntouched() {
        let text = "The token bucket algorithm refills tokens. Password managers help. See https://example.com/?page=2"
        let (out, counts) = redact(text)
        XCTAssertEqual(out, text)
        XCTAssertTrue(counts.isEmpty)
    }
}

final class BundleTests: XCTestCase {
    func testSetRedactsAndCounts() {
        var b = ContextBundle(app: AppInfo(name: "Terminal", bundleID: "com.apple.Terminal", pid: 1))
        b.set(.selection, "export GITHUB_TOKEN=ghp_" + String(repeating: "q", count: 36))
        XCTAssertEqual(b.redactionCount, 1)
        XCTAssertFalse(b.selection!.contains("ghp_"))
        b.set(.url, "")
        XCTAssertNil(b.url)
    }

    func testSameSecretInTwoFieldsCountsOnce() {
        var b = ContextBundle(app: AppInfo(name: "Safari", bundleID: "com.apple.Safari", pid: 1))
        let key = "AKIA" + String(repeating: "Q", count: 16)
        b.set(.selection, key)
        b.setPage(PageText(text: "config \(key) here", headings: [], method: .textMarkers))
        XCTAssertEqual(b.redactionCount, 1)
        XCTAssertFalse(b.page!.text.contains(key))
    }

    func testEncodingLeavesOutSeenSecrets() throws {
        var b = ContextBundle(app: AppInfo(name: "Safari", bundleID: nil, pid: 1))
        b.set(.selection, "AKIA" + String(repeating: "Q", count: 16))
        let json = String(data: try JSONEncoder().encode(b), encoding: .utf8)!
        XCTAssertFalse(json.contains("seenSecrets"))
        let back = try JSONDecoder().decode(ContextBundle.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(back.redactionCount, 1)
    }

    func testBlockDropsEverythingButTheAppName() {
        var b = ContextBundle(app: AppInfo(name: "Safari", bundleID: "com.apple.Safari", pid: 1))
        b.set(.selection, "hello")
        b.set(.url, "https://chase.com")
        b.screenshotPath = "/tmp/x.png"
        b.block(reason: "chase.com is on the blocklist")
        XCTAssertNil(b.selection)
        XCTAssertNil(b.url)
        XCTAssertNil(b.screenshotPath)
        XCTAssertEqual(b.app.name, "Safari")
        XCTAssertTrue(b.isBlocked)
    }

    func testSelectionLabel() {
        XCTAssertEqual(Words.selectionLabel("one"), "1 word selected")
        XCTAssertEqual(Words.selectionLabel("two words"), "2 words selected")
        XCTAssertEqual(Words.selectionLabel("a\nb\nc\n"), "3 lines selected")
    }
}

final class BlocklistTests: XCTestCase {
    func testApps() {
        XCTAssertTrue(Blocklist.standard.blocksApp("com.1password.1password"))
        XCTAssertFalse(Blocklist.standard.blocksApp("com.apple.Safari"))
        XCTAssertFalse(Blocklist.standard.blocksApp(nil))
    }

    func testSitesMatchSubdomainsOnly() {
        let b = Blocklist(apps: [], sites: ["chase.com", "*.bank.example", "https://www.paypal.com/login"])
        XCTAssertEqual(b.blockedSite(for: "https://secure.chase.com/x"), "chase.com")
        XCTAssertEqual(b.blockedSite(for: "https://www.chase.com"), "chase.com")
        XCTAssertNil(b.blockedSite(for: "https://notchase.com"))
        XCTAssertNotNil(b.blockedSite(for: "https://app.bank.example/"))
        XCTAssertNotNil(b.blockedSite(for: "https://paypal.com/myaccount"))
        XCTAssertNil(b.blockedSite(for: nil))
    }

    func testPrivateWindowTitles() {
        XCTAssertTrue(Blocklist.looksPrivate(windowTitle: "Docs — Mozilla Firefox Private Browsing"))
        XCTAssertTrue(Blocklist.looksPrivate(windowTitle: "New Tab - Google Chrome (Incognito)"))
        XCTAssertFalse(Blocklist.looksPrivate(windowTitle: "Wikipedia"))
    }

    func testDomainNormalize() {
        XCTAssertEqual(Domain.normalize("  https://www.Chase.com/login "), "chase.com")
        XCTAssertEqual(Domain.normalize("*.example.org"), "example.org")
        XCTAssertNil(Domain.normalize("   "))
    }
}

final class SettingsTests: XCTestCase {
    func testFullPageRules() {
        var s = AppSettings()
        XCTAssertFalse(s.wantsFullPage(url: "https://docs.swift.org/x"))
        s.fullPageSites = ["swift.org"]
        XCTAssertTrue(s.wantsFullPage(url: "https://docs.swift.org/x"))
        XCTAssertFalse(s.wantsFullPage(url: "https://example.com"))
        s.fullPageByDefault = true
        XCTAssertTrue(s.wantsFullPage(url: nil))
    }

    func testOldSettingsStillDecode() throws {
        let json = #"{"fullPageByDefault": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(s.fullPageByDefault)
        XCTAssertEqual(s.hotkey, .optionSpace)
        XCTAssertEqual(s.blocklist, .standard)
    }
}

final class ExcerptTests: XCTestCase {
    func testAroundSelection() {
        let full = String(repeating: "a", count: 100) + "NEEDLE" + String(repeating: "b", count: 100)
        let out = PageExcerpt.make(full: full, selection: "NEEDLE", headings: [Heading(level: 2, text: "Intro")], window: 10)
        XCTAssertTrue(out.hasPrefix("Page outline:\n  - Intro\n\nText around the selection:\n… "))
        XCTAssertTrue(out.contains("aaaaaaaaaaNEEDLEbbbbbbbbbb"))
        XCTAssertTrue(out.hasSuffix(" …"))
    }

    func testStartOfPageWithoutSelection() {
        let out = PageExcerpt.make(full: "short page", selection: nil, headings: [], window: 10)
        XCTAssertEqual(out, "Start of the page:\nshort page")
    }

    func testEmptyPage() {
        XCTAssertEqual(PageExcerpt.make(full: "", selection: "x", headings: [], window: 10), "Start of the page:\n")
    }
}

final class PromptTextTests: XCTestCase {
    func testRendersContext() {
        var b = ContextBundle(app: AppInfo(name: "Safari", bundleID: "com.apple.Safari", pid: 1))
        b.set(.app, "Swift Concurrency")
        b.set(.url, "https://docs.swift.org/concurrency")
        b.set(.selection, "actors")
        b.setPage(PageText(text: "Intro. actors isolate state. End.", headings: [], method: .textMarkers))
        let out = PromptText.render(request: "explain this ", bundle: b, fullPage: false)
        XCTAssertTrue(out.hasPrefix("explain this\n\n---\nContext captured by Superclick:\n- App: Safari — \u{201C}Swift Concurrency\u{201D}\n- URL: https://docs.swift.org/concurrency"))
        XCTAssertTrue(out.contains("Text around the selection"))
        let full = PromptText.render(request: "x", bundle: b, fullPage: true)
        XCTAssertTrue(full.contains("- Full page text (5 words):"))
    }

    func testFenceOutgrowsBackticks() {
        XCTAssertEqual(PromptText.fenced("a ```b``` c"), "````\na ```b``` c\n````")
    }

    func testBlockedBundleSaysWhy() {
        var b = ContextBundle(app: AppInfo(name: "1Password", bundleID: "com.1password.1password", pid: 1))
        b.block(reason: "on the blocklist")
        XCTAssertTrue(PromptText.render(request: "hi", bundle: b, fullPage: false)
            .hasSuffix("- App: 1Password (not captured: on the blocklist)"))
    }
}

final class ChipOverflowTests: XCTestCase {
    let stack: (Int) -> Double = { _ in 30 }

    func testEverythingFits() {
        let r = ChipOverflow.layout(widths: [50, 50, 50], pinned: [], available: 200, spacing: 4, stackWidth: stack)
        XCTAssertEqual(r, .init(visible: [0, 1, 2], tucked: []))
    }

    func testTucksFromTheEndButKeepsPinned() {
        // 5 chips of 60; the last (secret) is pinned.
        let r = ChipOverflow.layout(widths: [60, 60, 60, 60, 60], pinned: [4], available: 200, spacing: 4, stackWidth: stack)
        // 60 + 60 + 60(pinned) + 30(stack) + 3 gaps = 222 > 200, so only one regular chip stays.
        XCTAssertEqual(r.visible, [0, 4])
        XCTAssertEqual(r.tucked, [1, 2, 3])
    }

    func testGivesUpWhenOnlyPinnedRemain() {
        let r = ChipOverflow.layout(widths: [500, 500], pinned: [0, 1], available: 100, spacing: 4, stackWidth: stack)
        XCTAssertEqual(r.visible, [0, 1])
        XCTAssertEqual(r.tucked, [])
    }
}
