import AppKit
import Combine
import SuperclickCapture
import SuperclickCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var hotKeyFailed = false
    private let daemon = DaemonClient()
    private lazy var bubble = BubbleController(daemon: daemon)
    private var windows: [String: NSWindow] = [:]
    private var cancellables: Set<AnyCancellable> = []
    let diagnostics = DiagnosticsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Screenshot.clearOld()
        setUpStatusItem()
        registerHotKey()
        bubble.onReport = { [weak self] report in
            // A slow, older summon must not overwrite a newer one's report.
            guard let self else { return }
            if let last = self.diagnostics.last, last.at > report.at { return }
            self.diagnostics.last = report
        }
        bubble.onBackgroundChange = { [weak self] in self?.updateStatusIcon() }
        Notifier.shared.setUp()
        Notifier.shared.onAction = { [weak self] requestID, approvalID, action in
            self?.bubble.handle(requestID: requestID, approvalID: approvalID, action: action)
        }
        daemon.connect()

        // Re-register when the shortcut changes in Settings.
        SettingsStore.shared.$value
            .map(\.hotkey)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.registerHotKey() }
            }
            .store(in: &cancellables)

        // The menu-bar icon carries status (DECISIONS: notifications live in the menu bar).
        Permissions.shared.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.updateStatusIcon() } }
            .store(in: &cancellables)

        if !SettingsStore.shared.value.onboardingDone || !Permissions.shared.accessibility {
            showOnboarding()
        }
    }

    // MARK: Hotkey

    private func registerHotKey() {
        hotKey?.unregister()
        let preset = SettingsStore.shared.value.hotkey
        hotKey = HotKey(preset: preset) { [weak self] in
            self?.bubble.toggle(summonedAt: now())
        }
        hotKeyFailed = hotKey == nil
        updateStatusIcon()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private var needsAttention: Bool {
        !Permissions.shared.accessibility || hotKeyFailed || bubble.hasWaitingAnswer
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let base = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Superclick")
            ?? NSImage()
        button.image = needsAttention ? Self.badged(base) : base
        button.image?.isTemplate = !needsAttention
        // How many closed requests need you, next to the icon (SPEC: menu-bar badge).
        let count = bubble.waiting.count
        statusItem.length = count > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.title = count > 0 ? "\(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.toolTip = bubble.hasWaitingAnswer ? "An answer is waiting" : needsAttention ? "Superclick needs your attention" : "Superclick"
    }

    /// The template icon with a small orange dot, drawn in the menu bar's text color.
    private static func badged(_ image: NSImage) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            // Drawn lazily, so labelColor matches the menu bar's appearance at draw time.
            let glyph = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let g = image.size
            glyph.draw(in: NSRect(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2, width: g.width, height: g.height))
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 5, height: 5)).fill()
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        Permissions.shared.refresh()
        let settings = SettingsStore.shared.value

        // Waiting work lives here, not on the cursor (DECISIONS).
        let waiting = bubble.waiting
        let working = bubble.working
        for m in waiting + working {
            menu.addItem(requestItem(m))
        }
        if waiting.isEmpty && working.isEmpty, let m = bubble.lastAnswered {
            menu.addItem(item("Show last answer · \(m.projectName)", #selector(showLastAnswer)))
        }
        if daemon.isConnected {
            menu.addItem(item("While you were away…", #selector(showCatchUp)))
        }
        if bubble.lastAnswered != nil || daemon.isConnected { menu.addItem(.separator()) }

        let summon = NSMenuItem(title: "Summon", action: #selector(summonFromMenu), keyEquivalent: "")
        summon.target = self
        if hotKeyFailed {
            summon.title = "Summon (\(settings.hotkey.label) is taken; pick another in Settings)"
        } else {
            summon.title = "Summon  \(settings.hotkey.label)"
        }
        menu.addItem(summon)
        menu.addItem(.separator())

        if !Permissions.shared.accessibility {
            menu.addItem(item("⚠︎ Grant Accessibility…", #selector(showOnboardingAction)))
        } else if !Permissions.shared.screenRecording {
            menu.addItem(item("Allow screenshots…", #selector(showOnboardingAction)))
        }
        if let r = diagnostics.last {
            let page = r.pageSinceHotkeyMs.map { ", page \($0) ms" } ?? ""
            let info = NSMenuItem(title: "Last summon: \(r.visibleMs ?? 0) ms to show\(page)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        let d = NSMenuItem(title: "Daemon: \(daemonText)", action: nil, keyEquivalent: "")
        d.isEnabled = false
        menu.addItem(d)
        menu.addItem(.separator())

        menu.addItem(item("Projects…", #selector(showProjects)))
        menu.addItem(item("Page-text check…", #selector(showDiagnostics)))
        menu.addItem(item("Permissions…", #selector(showOnboardingAction)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Superclick", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private var daemonText: String {
        switch daemon.state {
        case .notRunning: return "not running"
        case .connecting: return "connecting…"
        case .connected(let v): return "connected (\(v))"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    /// One line per request that needs you or is still going, with Stop for running ones.
    private func requestItem(_ m: BubbleModel) -> NSMenuItem {
        let asked = "\u{201C}\(m.askedText.prefix(36))\(m.askedText.count > 36 ? "…" : "")\u{201D}"
        let title: String
        if m.approval != nil {
            title = "⚠︎ \(m.projectName) needs your OK · \(asked)"
        } else if m.phase == .done {
            title = "● Answer ready in \(m.projectName) · \(asked)"
        } else if m.phase == .failed {
            title = "Failed in \(m.projectName) · \(asked)"
        } else {
            title = "Working in \(m.projectName) · \(asked)"
        }
        let i = NSMenuItem(title: title, action: #selector(showRequest(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = m
        if m.isBusy && m.approval == nil {
            let sub = NSMenu()
            let open = NSMenuItem(title: "Show", action: #selector(showRequest(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = m
            let stop = NSMenuItem(title: "Stop", action: #selector(stopRequest(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = m
            sub.addItem(open)
            sub.addItem(stop)
            i.submenu = sub
        }
        return i
    }

    @objc private func showRequest(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? BubbleModel else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.bubble.show(m)
        }
    }

    @objc private func stopRequest(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? BubbleModel else { return }
        bubble.stop(m)
    }

    @objc private func showLastAnswer() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.bubble.showLastAnswer()
        }
    }

    @objc private func summonFromMenu() {
        // Let the menu close and the previous app come back to the front first.
        let t = now()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.bubble.summon(summonedAt: t)
        }
    }

    // MARK: Windows

    @objc private func showOnboardingAction() { showOnboarding() }

    func showOnboarding() {
        Permissions.shared.startWatching()
        present(id: "onboarding", title: "Welcome to Superclick", size: NSSize(width: 520, height: 470)) {
            OnboardingView(onDone: { [weak self] in
                SettingsStore.shared.value.onboardingDone = true
                self?.windows["onboarding"]?.close()
                Permissions.shared.stopWatching()
            })
        }
    }

    @objc func showSettings() {
        present(id: "settings", title: "Superclick Settings", size: NSSize(width: 560, height: 560)) {
            SettingsView(store: SettingsStore.shared)
        }
    }

    @objc func showCatchUp() {
        let seen = SettingsStore.shared.value.catchUpSeenAt
        // First visit: the last day. After that, since the last visit.
        let since = seen > 0 ? Date(timeIntervalSince1970: seen) : Date().addingTimeInterval(-24 * 3600)
        SettingsStore.shared.value.catchUpSeenAt = Date().timeIntervalSince1970
        windows["catchup"]?.close()
        windows["catchup"] = nil
        present(id: "catchup", title: "While you were away", size: NSSize(width: 580, height: 620)) {
            CatchUpView(
                daemon: self.daemon, since: since,
                onShow: { [weak self] id in
                    guard let self, let m = self.bubble.model(forRequest: id) else { return false }
                    self.windows["catchup"]?.close()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        self.bubble.show(m)
                    }
                    return true
                },
                onAnswer: { [weak self] requestID, approvalID, allow, message in
                    guard let self else { return }
                    if let m = self.bubble.model(forRequest: requestID) {
                        self.bubble.answer(m, approval: approvalID, allow: allow, message: message)
                    } else {
                        self.daemon.answerApproval(id: approvalID, requestID: requestID, allow: allow, message: message)
                        Notifier.shared.clear(approvalID: approvalID)
                    }
                })
        }
    }

    @objc func showProjects() {
        present(id: "projects", title: "Projects", size: NSSize(width: 600, height: 620)) {
            ProjectsView(daemon: self.daemon)
        }
    }

    @objc func showDiagnostics() {
        present(id: "diagnostics", title: "Page-text check", size: NSSize(width: 620, height: 600)) {
            DiagnosticsView(store: self.diagnostics)
        }
    }

    private func present<V: View>(id: String, title: String, size: NSSize, @ViewBuilder content: () -> V) {
        if let w = windows[id] {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        windows[id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.windows[id] = nil
                if id == "onboarding" { Permissions.shared.stopWatching() }
                self?.updateStatusIcon()
            }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

/// Holds the last capture report for the Diagnostics window and the menu.
@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published var last: CaptureReport?
}
