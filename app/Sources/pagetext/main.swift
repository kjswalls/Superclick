import AppKit
import ApplicationServices
import Foundation
import SuperclickCapture
import SuperclickCore

// pagetext: the M1 page-text check. Reads the frontmost browser page's text
// through Accessibility with the same code the app uses, and reports what it
// got and how long it took.
//
//   swift run pagetext                       # waits 3 s; switch to the browser meanwhile
//   swift run pagetext --app com.google.Chrome
//   swift run pagetext --delay 5 --out ~/Desktop
//   swift run pagetext --dump                # also list the window's AX attributes

var delay = 3.0
var bundleID: String?
var outDir = FileManager.default.currentDirectoryPath
var dump = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--delay": delay = Double(args.isEmpty ? "3" : args.removeFirst()) ?? 3
    case "--app": bundleID = args.isEmpty ? nil : args.removeFirst()
    case "--out": outDir = (args.isEmpty ? outDir : (args.removeFirst() as NSString).expandingTildeInPath)
    case "--dump": dump = true
    case "-h", "--help":
        print("usage: pagetext [--app <bundle id>] [--delay <seconds>] [--out <dir>] [--dump]")
        exit(0)
    default:
        print("unknown option \(a)"); exit(2)
    }
}

// 1. Permission. The prompt names the app that launched us (Terminal, iTerm, VS Code…).
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
guard trusted else {
    print("""
    Accessibility permission is missing.
    Open System Settings → Privacy & Security → Accessibility, turn on the app you ran this from
    (for example Terminal), quit and reopen that app, then run this again.
    """)
    exit(1)
}

// 2. Find the target app.
var pid: pid_t = 0
if let id = bundleID {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
        print("\(id) isn't running."); exit(1)
    }
    pid = app.processIdentifier
} else {
    print("Switch to the browser now. Reading the frontmost app in \(Int(delay)) s…")
    pump(seconds: delay)
    guard let front = NSWorkspace.shared.frontmostApplication else {
        print("Couldn't find the frontmost app."); exit(1)
    }
    pid = front.processIdentifier
}
let running = NSRunningApplication(processIdentifier: pid)
let appName = running?.localizedName ?? "pid \(pid)"
let appBundleID = running?.bundleIdentifier

// 3. Quick context (what the bubble shows first), then the page.
let quick = QuickContext.read(pid: pid, bundleID: appBundleID)
var options = PageReader.Options()
options.walkSeconds = 5
options.alwaysWalk = true
let r = PageReader.read(pid: pid, bundleID: appBundleID, options: options)

if dump {
    let app = AXUIElementCreateApplication(pid)
    if let w = axElement(app, kAXFocusedWindowAttribute as String) {
        var names: CFArray?
        AXUIElementCopyAttributeNames(w, &names)
        print("Window attributes:")
        for n in (names as? [String]) ?? [] {
            let v = axAttr(w, n).map { String(describing: $0).prefix(100) } ?? "—"
            print("  \(n): \(v)")
        }
    }
}

guard let page = r.page else {
    print("No web page found in \(appName) — \"\(r.windowTitle ?? quick.windowTitle ?? "")\". Is a normal page in front?")
    print("Quick context: title \(quick.windowTitle ?? "none"), file \(quick.filePath ?? "none"), cwd \(quick.cwd ?? "none"), selection \(quick.selection.map { Words.selectionLabel($0) } ?? "none"), \(quick.ms) ms")
    exit(1)
}

// 4. What the app would keep: redacted, then trimmed to the default excerpt.
var bundle = ContextBundle(app: AppInfo(name: appName, bundleID: appBundleID, pid: pid))
bundle.set(.url, r.url)
bundle.set(.selection, r.selection ?? quick.selection)
bundle.setPage(page)
let full = bundle.page!.text
let trim = PageExcerpt.make(page: bundle.page!, selection: bundle.selection)
let blocked = AppSettings().blocklist.blockedSite(for: r.url)

// 5. Save and report.
let slug = appName.lowercased().replacingOccurrences(of: " ", with: "-")
let fullPath = (outDir as NSString).appendingPathComponent("pagetext-\(slug)-full.txt")
let trimPath = (outDir as NSString).appendingPathComponent("pagetext-\(slug)-trimmed.txt")
try? full.write(toFile: fullPath, atomically: true, encoding: .utf8)
try? trim.write(toFile: trimPath, atomically: true, encoding: .utf8)

func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
func verdict(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }

let best = r.fastestFullReadMs
let markers = r.markerText.flatMap { $0.isEmpty ? nil : $0 }
print("""

── Superclick page-text check ─────────────────────────────
App            \(appName) (\(appBundleID ?? "?"))
Window         \(r.windowTitle ?? "")
URL            \(r.url ?? "(none)")\(blocked.map { "  ← on the default blocklist (\($0)); the app wouldn't capture this page" } ?? "")
Setup          AXManualAccessibility: \(r.manualAXAccepted ? "accepted" : "not supported")\
\(r.usedEnhancedUI ? ", needed AXEnhancedUserInterface" : "")\(r.coldStart ? ", cold start" : "")
Quick context  \(quick.ms) ms (title, file, selection)
Find page      \(r.locateMs) ms

Selection      \(bundle.selection.map { "\(Words.selectionLabel($0)), \(r.selectionMs) ms" } ?? "none (\(r.selectionMs) ms)")
Text markers   \(markers.map { "\(Words.count($0)) words in \(r.markerMs) ms" } ?? "not supported (\(r.markerMs) ms)")
Tree walk      \(Words.count(r.walkText ?? "")) words in \(r.walkMs) ms, \(r.walkNodes) nodes\(r.walkTruncated ? ", STOPPED EARLY" : "")
Headings       \(page.headings.count)
Secrets        \(bundle.redactionCount) redacted
Trimmed        \(Words.count(trim)) words (what we'd send by default)

Starts with    \(oneLine(String(full.prefix(160))))
Ends with      \(oneLine(String(full.suffix(160))))

Speed          \(verdict(best < 300)) — \(best) ms for the fastest full read (target under 300 ms)
Off-screen     Check by eye: does "Ends with" match the article's last lines, without having scrolled there?

Saved          \(fullPath)
               \(trimPath)
────────────────────────────────────────────────────────────
""")
