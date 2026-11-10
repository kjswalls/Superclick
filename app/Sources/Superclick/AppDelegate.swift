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
        bubble.onReport = { [weak self] report in self?.diagnostics.last = report }
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
        !Permissions.shared.accessibility || hotKeyFailed
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let base = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Superclick")
            ?? NSImage()
        button.image = needsAttention ? Self.badged(base) : base
        button.image?.isTemplate = !needsAttention
        button.toolTip = needsAttention ? "Superclick needs your attention" : "Superclick"
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
        let settings = SettingsStore.shared.value

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
            Task { @MainActor in self?.windows[id] = nil }
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
