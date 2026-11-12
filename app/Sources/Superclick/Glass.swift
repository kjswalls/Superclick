import AppKit
import SwiftUI

/// The bubble's macOS glass: Liquid Glass on macOS 26, and on macOS 15 a
/// behind-window blur with a light gradient and an inner edge, close to the mockup.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            fallback(content, shape: shape)
        }
        #else
        fallback(content, shape: shape)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content, shape: RoundedRectangle) -> some View {
        content
            .background {
                ZStack {
                    VisualEffectBlur(material: .hudWindow)
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color.white.opacity(0.07), Color.white.opacity(0.02)]
                            : [Color.white.opacity(0.55), Color.white.opacity(0.25)],
                        startPoint: .top, endPoint: .bottom)
                }
                .clipShape(shape)
            }
            .overlay {
                // The light inner edge that makes glass read as glass.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.7),
                                 Color.white.opacity(scheme == .dark ? 0.05 : 0.2)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            }
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}
