import AppKit
import SuperclickCore
import SwiftUI

/// The bubble, top to bottom: context chips → request → routing chip →
/// reply (with any approval) → actions → footer.
struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    @ObservedObject var daemon: DaemonClient
    var onSubmit: () -> Void
    var onClose: () -> Void
    var onPaste: () -> Void
    var onApproval: (Bool) -> Void
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
                TextField(model.phase == .done ? "Reply…" : "Ask anything…", text: $model.request, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit(onSubmit)
                    .disabled(model.isBusy)
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(model.request.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(daemon.isConnected ? "Send to Claude Code" : "Copy the request with its context")
                .disabled(model.isBusy || model.request.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 14)

            if model.phase != .none {
                ReplyView(model: model, onPaste: onPaste, onApproval: onApproval)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

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
            if model.phase == .done {
                KeyHint(keys: "⌘↵", label: "paste here")
            } else if model.isBusy {
                KeyHint(keys: "esc", label: "hide; keeps working")
            } else {
                KeyHint(keys: "↵", label: daemon.isConnected ? "send" : "copy with context")
            }
            if !model.isBusy { KeyHint(keys: "esc", label: "close") }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }
}

/// The agent's answer as it streams, the approval card, and the actions.
struct ReplyView: View {
    @ObservedObject var model: BubbleModel
    var onPaste: () -> Void
    var onApproval: (Bool) -> Void
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let route = model.routeLabel {
                Text(route)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(Color.accentColor)
                    .help(model.routeReason ?? "")
            }

            ForEach(Array(model.toolLines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if model.phase == .waiting && model.replyText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
            }

            if !model.replyText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(Self.markdown(model.replyText))
                            .font(.system(size: 13.5))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: model.replyText) { _, _ in
                        if model.isBusy { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }

            if let a = model.approval { approvalCard(a) }

            if model.phase == .done {
                HStack(spacing: 8) {
                    Button(action: onPaste) {
                        Label("Paste here", systemImage: "arrow.down.doc")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.answerText, forType: .string)
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private func approvalCard(_ a: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Color(hex: 0xD2832A))
                Text("\(a.tool) needs your OK").font(.system(size: 12.5, weight: .semibold))
            }
            Text(a.summary)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            // Every choice also takes typed input (DECISIONS).
            TextField("Or tell Claude what to do instead…", text: $model.approvalReply)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
                .focused($replyFocused)
                .onSubmit { onApproval(false) }
            HStack(spacing: 8) {
                if model.approvalReply.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Allow") { onApproval(true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Deny") { onApproval(false) }
                } else {
                    Button("Send instead") { onApproval(false) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color(hex: 0xF0B04B, opacity: 0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(hex: 0xF0B04B, opacity: 0.3)))
    }

    /// Inline Markdown (bold, code, links) with the line breaks kept.
    static func markdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
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
