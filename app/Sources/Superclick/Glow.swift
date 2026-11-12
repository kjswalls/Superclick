import AppKit
import SwiftUI

/// The rainbow, for big moments only: summon and paste (DECISIONS). One shot,
/// never looping. With Reduce Motion it's a still edge that fades.
enum Rainbow {
    static let colors: [Color] = [
        Color(hex: 0xFF5F6D), Color(hex: 0xFFB36B), Color(hex: 0xF5E663), Color(hex: 0x5EE7A0),
        Color(hex: 0x4FC3F7), Color(hex: 0x7C83FF), Color(hex: 0xD26BFF), Color(hex: 0xFF5F6D),
    ]

    static func angular(_ degrees: Double) -> AngularGradient {
        AngularGradient(colors: colors, center: .center, angle: .degrees(degrees))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// The bubble's summon edge: a 1px rainbow line at about 90% and a soft 6px
/// halo at about 35%, turning about 320° over 1.5 s, then gone.
struct RainbowEdge: ViewModifier {
    var token: Int
    var cornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0
    @State private var strength = 0.0

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    spinning
                        .mask {
                            RoundedRectangle(cornerRadius: cornerRadius + 1, style: .continuous)
                                .strokeBorder(lineWidth: 1)
                        }
                        .padding(-1)
                        .opacity(0.9 * strength)
                    spinning
                        .mask {
                            RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
                                .strokeBorder(lineWidth: 6)
                        }
                        .padding(-6)
                        .blur(radius: 4)
                        .opacity(0.35 * strength)
                }
                .allowsHitTesting(false)
            }
            .onChange(of: token, initial: true) { _, _ in play() }
    }

    /// Gradients don't animate their angle, so the gradient is turned instead,
    /// oversized so its corners never show.
    private var spinning: some View {
        Rainbow.angular(0)
            .scaleEffect(1.8)
            .rotationEffect(.degrees(angle))
    }

    private func play() {
        guard token > 0 else { return }
        angle = 0
        strength = 0
        if reduceMotion {
            strength = 0.9
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.easeOut(duration: 0.4)) { strength = 0 }
            }
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { strength = 1 }
        withAnimation(.timingCurve(0.3, 0.6, 0.3, 1, duration: 1.5)) { angle = 320 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(950))
            withAnimation(.easeIn(duration: 0.55)) { strength = 0 }
        }
    }
}

extension View {
    func rainbowEdge(token: Int, cornerRadius: CGFloat = 16) -> some View {
        modifier(RainbowEdge(token: token, cornerRadius: cornerRadius))
    }
}

// MARK: - Cursor glow

/// A short rainbow light travels around the pointer's outline (about 1.5 laps
/// in 1.1 s), the full outline glows once, then it's gone. It's drawn in our own
/// click-through overlay just under the real pointer, using the pointer's
/// actual image, so the system cursor is never replaced and a resized pointer
/// still fits. With Reduce Motion it's the full outline, still, for a moment.
@MainActor
final class CursorGlow {
    static let shared = CursorGlow()
    private var panel: NSPanel?
    private var follow: Timer?

    func play() {
        guard let cursor = NSCursor.currentSystem ?? Optional(NSCursor.arrow) else { return }
        let scale = Self.pointerScale()
        let image = cursor.image
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let hot = NSPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale)
        let pad: CGFloat = 14
        let frameSize = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)

        panel?.orderOut(nil)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: frameSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.contentView = NSHostingView(rootView: CursorGlowView(image: image, size: size, pad: pad, still: reduce))
        panel = p

        func place() {
            // The hot spot is measured from the image's top-left; window origins are bottom-left.
            let m = NSEvent.mouseLocation
            p.setFrameOrigin(NSPoint(x: m.x - hot.x - pad, y: m.y - (size.height - hot.y) - pad))
        }
        place()
        p.orderFrontRegardless()

        follow?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            Task { @MainActor in place() }
        }
        follow = timer
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduce ? 1300 : 1500))
            timer.invalidate()
            // A newer glow may have started meanwhile; leave its timer and panel alone.
            if self.follow === timer { self.follow = nil }
            if self.panel === p { p.orderOut(nil); self.panel = nil }
        }
    }

    /// The pointer size from System Settings → Accessibility → Display (1 to 4).
    static func pointerScale() -> CGFloat {
        let v = UserDefaults(suiteName: "com.apple.universalaccess")?.double(forKey: "mouseDriverCursorSize") ?? 1
        return CGFloat(min(max(v, 1), 4))
    }
}

private struct CursorGlowView: View {
    let image: NSImage
    let size: NSSize
    let pad: CGFloat
    let still: Bool
    @State private var angle = -90.0
    @State private var comet = 0.0
    @State private var ring = 0.0

    var body: some View {
        ZStack {
            // A comet: a bright arc of the rainbow that travels around the outline.
            AngularGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.55),
                    .init(color: Color(hex: 0xFF5F6D), location: 0.7),
                    .init(color: Color(hex: 0xF5E663), location: 0.8),
                    .init(color: Color(hex: 0x4FC3F7), location: 0.9),
                    .init(color: Color(hex: 0xD26BFF), location: 1),
                ],
                center: .center)
                .scaleEffect(1.8)
                .rotationEffect(.degrees(angle))
                .mask(rim(spread: 3.5))
                .opacity(comet)
            Rainbow.angular(0)
                .scaleEffect(1.8)
                .rotationEffect(.degrees(angle))
                .mask(rim(spread: 2.5))
                .opacity(ring)
        }
        .frame(width: size.width + pad * 2, height: size.height + pad * 2)
        .onAppear(perform: play)
    }

    /// The pointer's silhouette, grown by `spread`, minus the pointer itself, so only
    /// the rim outside its white edge lights up.
    private func rim(spread: CGFloat) -> some View {
        ZStack {
            silhouette.shadow(color: .black, radius: spread).shadow(color: .black, radius: spread / 2)
            silhouette.blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    private var silhouette: some View {
        Image(nsImage: image)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(.black)
            .frame(width: size.width, height: size.height)
    }

    private func play() {
        if still {
            ring = 0.95
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.easeOut(duration: 0.35)) { ring = 0 }
            }
            return
        }
        withAnimation(.easeOut(duration: 0.09)) { comet = 1 }
        withAnimation(.timingCurve(0.5, 0.05, 0.4, 1, duration: 1.1)) { angle = -90 + 540 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(680))
            withAnimation(.easeOut(duration: 0.15)) { ring = 0.9 }
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeOut(duration: 0.25)) { comet = 0 }
            withAnimation(.easeOut(duration: 0.35)) { ring = 0 }
        }
    }
}
