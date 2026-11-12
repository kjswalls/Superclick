import AppKit
import SwiftUI

/// Whether Claude Code is on this Mac. Superclick uses your own install, signed
/// in with your own account, and shows how to install it when it's missing.
struct ClaudeCodeStatusView: View {
    @ObservedObject var daemon: DaemonClient
    @State private var copied = false

    var body: some View {
        if !daemon.isConnected {
            Text("Start the daemon to check for Claude Code.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let c = daemon.claudeCode, c.installed {
            HStack(alignment: .firstTextBaseline) {
                Label("Claude Code", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text([c.version, c.path.map(ProjectRowPath.tilde) ?? "the development copy"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text("If requests say you're signed out, run `claude` once in Terminal and sign in.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let c = daemon.claudeCode {
            Label("Claude Code isn't installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Superclick runs your requests with Claude Code on this Mac. Install it with this command in Terminal, then run `claude` once to sign in.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let cmd = c.installCommand {
                HStack {
                    Text(cmd)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                if let s = c.installURL, let url = URL(string: s) {
                    Button("Open the install guide") { NSWorkspace.shared.open(url) }
                }
                Button("Check again") { daemon.checkAgents() }
            }
            .controlSize(.small)
        }
    }
}

enum ProjectRowPath {
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
