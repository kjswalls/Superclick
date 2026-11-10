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

/// Shows the bubble at the cursor on summon, runs one capture per summon, and
/// sends the request to the agent through the daemon.
@MainActor
final class BubbleController: NSObject, NSWindowDelegate {
    private let panel = BubblePanel()
    private var model: BubbleModel?
    /// The last bubble whose request went to the agent, for "Show last answer".
    private(set) var lastAnswered: BubbleModel?
    private var clickMonitor: Any?
    private var anchor: NSPoint = .zero
    private var placeAbove = false
    let daemon: DaemonClient
    var onReport: ((CaptureReport) -> Void)?
    /// Something changed on a closed bubble (an answer is ready, or it needs approval).
    var onBackgroundChange: (() -> Void)?
    /// The last app other than Superclick to be active, so the hotkey works
    /// while one of our own windows is in front.
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: Any?

    init(daemon: DaemonClient) {
        self.daemon = daemon
        super.init()
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me {
            lastExternalApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != me else { return }
            Task { @MainActor in self?.lastExternalApp = app }
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// True when a closed bubble has an answer or an approval waiting.
    var hasWaitingAnswer: Bool {
        guard let m = lastAnswered, m !== model || !panel.isVisible else { return false }
        if m.approval != nil { return true }
        return (m.phase == .done || m.phase == .failed) && !m.seen
    }

    func toggle(summonedAt: Double) {
        if panel.isVisible { close() } else { summon(summonedAt: summonedAt) }
    }

    func summon(summonedAt: Double) {
        Permissions.shared.refresh()
        let me = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let front = (frontmost?.processIdentifier == me ? lastExternalApp : frontmost) ?? lastExternalApp,
              !front.isTerminated else { return }

        let settings = SettingsStore.shared.value
        let model = BubbleModel(app: front, summonedAt: summonedAt, settings: settings)
        present(model)
        model.markVisible()
        model.start(onReport: { [weak self] report in self?.onReport?(report) })
        CursorGlow.shared.play()
    }

    /// Reopens the last answered bubble at the pointer (from the menu bar).
    func showLastAnswer() {
        guard let m = lastAnswered else { return }
        if panel.isVisible { close() }
        present(m)
        m.seen = true
        onBackgroundChange?()
    }

    private func present(_ model: BubbleModel) {
        self.model = model
        let view = BubbleView(
            model: model, daemon: daemon,
            onSubmit: { [weak self] in self?.submit() },
            onClose: { [weak self] in self?.close() },
            onPaste: { [weak self] in self?.paste() },
            onApproval: { [weak self] allow in self?.answerApproval(allow: allow) },
            onHeightChange: { [weak self] h in self?.resize(height: h) })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting

        anchor = NSEvent.mouseLocation
        placeAbove = false
        let size = hosting.fittingSize
        resize(height: max(size.height, 120), force: true)

        panel.makeKeyAndOrderFront(nil)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    /// Keeps the bubble's top-left just below-right of the pointer, flipping
    /// above it near the bottom of the screen, and always on screen.
    private func resize(height: CGFloat, force: Bool = false) {
        let width = BubbleView.width + BubbleView.margin * 2
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = NSPoint(x: 6, y: 18)

        var x = anchor.x + offset.x - BubbleView.margin
        if force || !panel.isVisible {
            placeAbove = anchor.y - offset.y - height < visible.minY
        }
        var y = placeAbove ? anchor.y + 8 - BubbleView.margin : anchor.y - offset.y - height + BubbleView.margin
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func submit() {
        guard let model, !model.isBusy else { return }
        let text = model.request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Wait for the URL check: nothing leaves the bubble before the blocklist has seen the page.
        guard model.captureFinished else {
            model.status = "Finishing the capture…"
            model.whenCaptured { [weak self, weak model] in
                guard let self, let model, self.model === model else { return }
                model.status = nil
                self.submit()
            }
            return
        }

        let prompt = model.promptText
        if daemon.isConnected {
            model.onBackgroundChange = { [weak self] in self?.onBackgroundChange?() }
            let id = daemon.sendRequest(text: text, prompt: prompt, bundle: model.bundle, fullPage: model.fullPage) {
                [weak model] event in model?.apply(event)
            }
            if let id {
                model.beginRequest(id: id, text: text)
                lastAnswered = model
                return
            }
        }

        // No agent: copy the request with its context, ready to paste into Claude Code.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        withAnimation { model.status = "Copied with context. Start the daemon to ask Claude Code from here." }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if self.model === model { self.close() }
        }
    }

    private func answerApproval(allow: Bool) {
        guard let model, let a = model.approval else { return }
        let typed = model.approvalReply.trimmingCharacters(in: .whitespacesAndNewlines)
        daemon.answerApproval(id: a.id, allow: allow && typed.isEmpty, message: typed.isEmpty ? nil : typed)
        model.clearApproval()
        onBackgroundChange?()
    }

    /// Paste here: hide the bubble, paste the answer into the app underneath,
    /// and play the paste glow.
    private func paste() {
        guard let model else { return }
        let text = model.answerText
        guard !text.isEmpty else { return }
        model.seen = true
        close()
        Paster.paste(text)
        CursorGlow.shared.play()
        onBackgroundChange?()
    }

    func close() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        panel.orderOut(nil)
        panel.contentView = nil
        if let model {
            // A screenshot that was never sent is deleted now; one the agent has stays until the daily cleanup.
            model.markClosed(keepScreenshot: model.requestID != nil)
            if model.phase == .done || model.phase == .failed { model.seen = true }
        }
        model = nil
        onBackgroundChange?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking into another app or window dismisses the bubble.
        close()
    }
}

/// Pastes text into the frontmost app with ⌘V, then puts the clipboard back.
enum Paster {
    @MainActor
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCount = pb.changeCount

        Task { @MainActor in
            // Give the window server a moment to hand keyboard focus back to the app.
            try? await Task.sleep(for: .milliseconds(60))
            let source = CGEventSource(stateID: .combinedSessionState)
            let v = CGKeyCode(9) // kVK_ANSI_V
            let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)

            try? await Task.sleep(for: .milliseconds(700))
            // Restore what was on the clipboard, unless something else changed it meanwhile.
            if pb.changeCount == changeCount, !saved.isEmpty {
                pb.clearContents()
                pb.writeObjects(saved)
            }
        }
    }
}
