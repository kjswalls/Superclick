import AppKit

/// Superclick lives in the menu bar: no Dock icon, no main window.
@main
@MainActor
enum SuperclickMain {
    // NSApplication holds its delegate weakly.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
