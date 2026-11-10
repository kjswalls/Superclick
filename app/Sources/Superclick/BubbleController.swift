import AppKit
import SuperclickCapture
import SuperclickCore
import SwiftUI

/// A borderless panel that takes keystrokes without activating Superclick,
/// so the app you summoned over stays frontmost and its selection stays put.
final class BubblePanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 488, height: 160),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the SwiftUI view draws its own, outside the glow
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Shows the bubble at the cursor on summon and runs one capture per summon.
@MainActor
final class BubbleController: NSObject, NSWindowDelegate {
    private let panel = BubblePanel()
    private var model: BubbleModel?
    private var clickMonitor: Any?
    private var anchor: NSPoint = .zero
    private var placeAbove = false
    let daemon: DaemonClient
    var onReport: ((CaptureReport) -> Void)?

    init(daemon: DaemonClient) {
        self.daemon = daemon
        super.init()
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(summonedAt: Double) {
        if panel.isVisible { close() } else { summon(summonedAt: summonedAt) }
    }

    func summon(summonedAt: Double) {
        // The app in front before we appear. If that's us (a settings window), there's nothing to capture.
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let settings = SettingsStore.shared.value
        let model = BubbleModel(app: front, summonedAt: summonedAt, settings: settings)
        self.model = model

        let view = BubbleView(
            model: model, daemon: daemon,
            onSubmit: { [weak self] in self?.submit() },
            onClose: { [weak self] in self?.close() },
            onHeightChange: { [weak self] h in self?.resize(height: h) })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting

        anchor = NSEvent.mouseLocation
        let size = hosting.fittingSize
        resize(height: max(size.height, 120))

        panel.makeKeyAndOrderFront(nil)
        model.markVisible()
        model.start(onReport: { [weak self] report in self?.onReport?(report) })
        CursorGlow.shared.play()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    /// Keeps the bubble's top-left just below-right of the pointer, flipping
    /// above it near the bottom of the screen, and always on screen.
    private func resize(height: CGFloat) {
        let width = BubbleView.width + BubbleView.margin * 2
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = NSPoint(x: 6, y: 18)

        var x = anchor.x + offset.x - BubbleView.margin
        if !panel.isVisible {
            placeAbove = anchor.y - offset.y - height < visible.minY
        }
        var y = placeAbove ? anchor.y + 8 - BubbleView.margin : anchor.y - offset.y - height + BubbleView.margin
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func submit() {
        guard let model else { return }
        let text = model.request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // M1 has no agent yet: Enter copies the request with its context, ready to paste
        // into Claude Code. The daemon, if it's running, keeps a copy for M2.
        let prompt = model.promptText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        daemon.sendRequest(text: text, bundle: model.bundle, fullPage: model.fullPage)
        withAnimation { model.status = "Copied with context. Agent replies arrive in M2." }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if self.model === model { self.close() }
        }
    }

    func close() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        panel.orderOut(nil)
        panel.contentView = nil
        model = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking into another app or window dismisses the bubble.
        close()
    }
}
