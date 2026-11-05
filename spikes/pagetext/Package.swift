// swift-tools-version:5.9
import PackageDescription

// M1 spike: prove we can read a web page's full text (including what's
// scrolled off screen) through the macOS Accessibility API, fast enough
// to do on every summon. Throwaway code; the real capture lives in the app.
let package = Package(
    name: "PageTextSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "pagetext", path: "Sources/pagetext")
    ]
)
