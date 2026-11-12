import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility and Screen Recording, the two permissions M1 needs.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    /// Screen Recording only takes effect after a relaunch.
    @Published private(set) var screenRecordingNeedsRelaunch = false

    private var timer: Timer?

    var allGranted: Bool { accessibility && screenRecording }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
        let sr = CGPreflightScreenCaptureAccess()
        if sr != screenRecording { screenRecording = sr }
    }

    /// Polls while the onboarding window is open, so rows turn green as you flip switches.
    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in Permissions.shared.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func requestScreenRecording() {
        // Shows the system prompt the first time; afterwards it only adds us to the list.
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
        screenRecordingNeedsRelaunch = true
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
