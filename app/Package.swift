// swift-tools-version:6.0
import PackageDescription

// Superclick M1: menu-bar app, global hotkey, bubble at the cursor, context
// capture and permissions onboarding. Build the .app with ../scripts/build-app.sh.
let package = Package(
    name: "Superclick",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Superclick", targets: ["Superclick"]),
        .executable(name: "pagetext", targets: ["pagetext"]),
    ],
    targets: [
        // Pure logic with no AppKit: context bundle, redaction, blocklist,
        // page excerpt, prompt text, chip overflow. Unit tested.
        .target(name: "SuperclickCore"),
        // Accessibility and ScreenCaptureKit capture, shared by the app and the
        // page-text check.
        .target(name: "SuperclickCapture", dependencies: ["SuperclickCore"]),
        .executableTarget(name: "Superclick", dependencies: ["SuperclickCore", "SuperclickCapture"]),
        // The page-text check from the M1 spike, as a command-line tool.
        .executableTarget(name: "pagetext", dependencies: ["SuperclickCore", "SuperclickCapture"]),
        .testTarget(name: "SuperclickCoreTests", dependencies: ["SuperclickCore"]),
    ],
    // Swift 5 language mode keeps strict-concurrency diagnostics as warnings
    // while the AppKit glue settles. Move to .v6 once it builds clean.
    swiftLanguageModes: [.v5]
)
