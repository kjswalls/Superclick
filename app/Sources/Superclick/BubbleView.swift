import SuperclickCore
import SwiftUI

/// The bubble, top to bottom: context chips → request → status → footer.
/// (The routing chip and reply arrive with the daemon and coordinator in M2–M3.)
struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    @ObservedObject var daemon: DaemonClient
    var onSubmit: () -> Void
    var onClose: () -> Void
    var onHeightChange: (CGFloat) -> Void

    @FocusState private var inputFocused: Bool
    static let width: CGFloat = 460
    static let margin: CGFloat = 14 // room for the glow halo and shadow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChipsRow(
                chips: model.chips, width: Self.width - 28, expanded: $model.chipsExpanded,
                onRemove: { chip in
                    if case .item(let kind) = chip.kind { model.remove(kind) }
                },
                onToggle: { _ in model.fullPage.toggle() })
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 2)

            HStack(alignment: .center, spacing: 6) {
                TextField("Ask anything…", text: $model.request, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit(onSubmit)
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(model.request.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Copy the request with its context")
                .disabled(model.request.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 14)

            if let status = model.status {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }

            Divider().opacity(0.6)
            footer
        }
        .frame(width: Self.width)
        .glass(cornerRadius: 16)
        .rainbowEdge(token: model.glowToken)
        .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .padding(Self.margin)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .onAppear { inputFocused = true }
        .onExitCommand(perform: onClose)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            AgentMark()
            Text("Claude Code")
                .font(.system(size: 12, weight: .medium))
            Text(daemon.state.label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .help(daemon.state.help)
            Spacer()
            KeyHint(keys: "↵", label: "copy with context")
            KeyHint(keys: "esc", label: "close")
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }
}

/// The engraved copper plate for Claude Code: our own generic spark glyph
/// cut into a metal-tinted tile (DECISIONS, mockup round 4).
struct AgentMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xE7B08C), Color(hex: 0xC98059)], startPoint: .top, endPoint: .bottom))
            .frame(width: 18, height: 18)
            .overlay {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x6E3416))
                    .shadow(color: .white.opacity(0.35), radius: 0, y: 0.6)
            }
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }
}
