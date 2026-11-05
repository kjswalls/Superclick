import AppKit
import ApplicationServices
import Foundation

// pagetext: read the frontmost browser page's text through Accessibility and
// report what we got and how long it took.
//
//   swift run pagetext                       # waits 3 s; switch to the browser meanwhile
//   swift run pagetext --app com.google.Chrome
//   swift run pagetext --delay 5 --out ~/Desktop

var delay = 3.0
var bundleID: String?
var outDir = FileManager.default.currentDirectoryPath

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--delay": delay = Double(args.isEmpty ? "3" : args.removeFirst()) ?? 3
    case "--app": bundleID = args.isEmpty ? nil : args.removeFirst()
    case "--out": outDir = (args.isEmpty ? outDir : (args.removeFirst() as NSString).expandingTildeInPath)
    case "-h", "--help":
        print("usage: pagetext [--app <bundle id>] [--delay <seconds>] [--out <dir>]")
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
    let system = AXUIElementCreateSystemWide()
    guard let focused = axElement(system, kAXFocusedApplicationAttribute as String) else {
        print("Couldn't find the frontmost app."); exit(1)
    }
    AXUIElementGetPid(focused, &pid)
}
let running = NSRunningApplication(processIdentifier: pid)
let appName = running?.localizedName ?? "pid \(pid)"
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2.0)

// 3. Chromium and Electron only build their web accessibility tree when asked.
//    AXManualAccessibility is the gentle switch; AXEnhancedUserInterface is the
//    older one, which can upset window animations, so we turn it back off after.
let tStart = now()
let manualErr = axSetBool(app, "AXManualAccessibility", true)

func locateWebArea() -> (AXUIElement?, AXUIElement?) {
    let window = axElement(app, kAXFocusedWindowAttribute as String)
        ?? axElement(app, kAXMainWindowAttribute as String)
    guard let w = window else { return (nil, nil) }
    return (w, findFirst(role: "AXWebArea", under: w))
}

var (foundWindow, foundWeb) = locateWebArea()
var usedEnhanced = false
var coldStart = false
if foundWeb == nil || (foundWeb.map { axChildren($0).isEmpty } ?? true) {
    // First access to a Chromium tab can take a moment to populate.
    coldStart = true
    pump(seconds: 0.5)
    (foundWindow, foundWeb) = locateWebArea()
    if foundWeb == nil {
        usedEnhanced = axSetBool(app, "AXEnhancedUserInterface", true) == .success
        pump(seconds: 1.0)
        (foundWindow, foundWeb) = locateWebArea()
    }
}
let tLocate = ms(since: tStart)

guard let window = foundWindow else { print("\(appName) has no focused window."); exit(1) }
let title = axString(window, kAXTitleAttribute as String) ?? ""
guard let web = foundWeb else {
    print("No web page found in \(appName) — \"\(title)\". Is a normal page in front?")
    if usedEnhanced { axSetBool(app, "AXEnhancedUserInterface", false) }
    exit(1)
}

// 4. URL and selection.
let url = (axAttr(web, "AXURL") as? URL)?.absoluteString
    ?? axString(window, kAXDocumentAttribute as String) ?? "(none)"
let tSel = now()
var selection = selectionViaMarkers(web)
if selection?.isEmpty ?? true,
   let focusedEl = axElement(app, kAXFocusedUIElementAttribute as String) {
    selection = axString(focusedEl, kAXSelectedTextAttribute as String)
}
let selMs = ms(since: tSel)

// 5. Full text, both ways, timed.
let tA = now()
let markerText = textViaMarkers(web)
let markerMs = ms(since: tA)

let tB = now()
let walker = TreeWalker()
walker.walk(web)
let walkText = walker.text
let walkMs = ms(since: tB)

if usedEnhanced { axSetBool(app, "AXEnhancedUserInterface", false) }

let full = (markerText?.isEmpty == false) ? markerText! : walkText
let trim = trimmed(full: full, selection: selection, headings: walker.headings)

// 6. Save and report.
let slug = appName.lowercased().replacingOccurrences(of: " ", with: "-")
let fullPath = (outDir as NSString).appendingPathComponent("pagetext-\(slug)-full.txt")
let trimPath = (outDir as NSString).appendingPathComponent("pagetext-\(slug)-trimmed.txt")
try? full.write(toFile: fullPath, atomically: true, encoding: .utf8)
try? trim.write(toFile: trimPath, atomically: true, encoding: .utf8)

func tail(_ s: String, _ n: Int) -> String {
    String(s.suffix(n)).replacingOccurrences(of: "\n", with: " ")
}
func head(_ s: String, _ n: Int) -> String {
    String(s.prefix(n)).replacingOccurrences(of: "\n", with: " ")
}
func verdict(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }

let best = min(markerText?.isEmpty == false ? markerMs : Int.max, walkMs)
print("""

── Superclick page-text spike ─────────────────────────────
App            \(appName) (\(running?.bundleIdentifier ?? "?"))
Window         \(title)
URL            \(url)
Setup          AXManualAccessibility: \(manualErr == .success ? "accepted" : "not supported (\(manualErr.rawValue))")\
\(usedEnhanced ? ", needed AXEnhancedUserInterface" : "")\(coldStart ? ", cold start" : "")
Find page      \(tLocate) ms

Selection      \(selection.map { "\(wordCount($0)) words, \(selMs) ms" } ?? "none (\(selMs) ms)")
Text markers   \(markerText.map { "\(wordCount($0)) words in \(markerMs) ms" } ?? "not supported (\(markerMs) ms)")
Tree walk      \(wordCount(walkText)) words in \(walkMs) ms, \(walker.nodes) nodes\(walker.truncated ? ", STOPPED EARLY" : "")
Headings       \(walker.headings.count)
Trimmed        \(wordCount(trim)) words (what we'd send by default)

Starts with    \(head(full, 160))
Ends with      \(tail(full, 160))

Speed          \(verdict(tLocate + best < 300)) — \(tLocate + best) ms for the fastest full read (target under 300 ms)
Off-screen     Check by eye: does "Ends with" match the article's last lines, without having scrolled there?

Saved          \(fullPath)
               \(trimPath)
────────────────────────────────────────────────────────────
""")
