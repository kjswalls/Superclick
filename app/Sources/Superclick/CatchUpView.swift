import AppKit
import SwiftUI

/// "While you were away" (SPEC flow 3, M4): one card per project with what
/// ran, what changed, what's waiting on you, and how each request ended, so a
/// long task can be picked up without reading its whole log.
struct CatchUpView: View {
    @ObservedObject var daemon: DaemonClient
    let since: Date
    /// Opens the request's bubble, if the app still has it.
    var onShow: (String) -> Bool
    /// Answers an approval: request id, approval id, allow, typed message.
    var onAnswer: (String, String, Bool, String?) -> Void
    @State private var range: Range = .sinceLastVisit

    enum Range: String, CaseIterable, Identifiable {
        case sinceLastVisit = "Since you were last here"
        case day = "Last 24 hours"
        case week = "Last 7 days"
        var id: String { rawValue }
    }

    private var start: Date {
        switch range {
        case .sinceLastVisit: return since
        case .day: return Date().addingTimeInterval(-24 * 3600)
        case .week: return Date().addingTimeInterval(-7 * 24 * 3600)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button { daemon.fetchCatchUp(since: start) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !daemon.isConnected {
                        empty("The daemon isn't running, so there's nothing to catch up on.")
                    } else if !daemon.catchUpLoaded {
                        ProgressView().frame(maxWidth: .infinity).padding(30)
                    } else if daemon.catchUp.isEmpty {
                        empty("Nothing happened while you were away.")
                    }
                    ForEach(daemon.catchUp) { card in
                        CardView(card: card, onShow: onShow, onAnswer: onAnswer)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear { daemon.fetchCatchUp(since: start) }
        .onChange(of: range) { _, _ in daemon.fetchCatchUp(since: start) }
        // An approval asked, answered or gone, or a summary updated: fetch the cards again.
        .onChange(of: daemon.approvalsChanged) { _, _ in daemon.fetchCatchUp(since: start) }
        .onChange(of: daemon.projects) { _, _ in daemon.fetchCatchUp(since: start) }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(30)
    }
}

private struct CardView: View {
    let card: CatchUpCard
    var onShow: (String) -> Bool
    var onAnswer: (String, String, Bool, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(card.project).font(.headline)
                Spacer()
                Text(counts).font(.caption).foregroundStyle(.secondary)
            }
            if !card.summary.isEmpty {
                Text(card.summary).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(card.requests) { r in
                RequestRow(request: r, onShow: onShow, onAnswer: onAnswer)
                if r.id != card.requests.last?.id { Divider() }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
    }

    private var counts: String {
        let waiting = card.requests.filter { $0.status == "waiting" }.count
        let done = card.requests.filter { $0.status == "done" }.count
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if done > 0 { parts.append("\(done) done") }
        return parts.joined(separator: " · ")
    }
}

private struct RequestRow: View {
    let request: CatchUpCard.Request
    var onShow: (String) -> Bool
    var onAnswer: (String, String, Bool, String?) -> Void
    @State private var typed = ""
    /// Approvals answered here, so the card moves on to the next one before the refetch arrives.
    @State private var answered: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(request.text.isEmpty ? "Request" : "\u{201C}\(request.text)\u{201D}")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Spacer()
                Text((request.endedAt ?? request.startedAt).formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !request.ran.isEmpty {
                Text("Ran: " + request.ran.suffix(4).joined(separator: " · "))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !request.changed.isEmpty {
                Text("Changed: " + request.changed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .help(request.changed.joined(separator: "\n"))
            }
            if let a = request.waiting.first(where: { !answered.contains($0.id) }) {
                approval(a)
            } else if let answer = request.answer, !answer.isEmpty {
                Text(answer)
                    .font(.system(size: 12.5))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack {
                if onShowAvailable {
                    Button("Open in bubble") { _ = onShow(request.id) }.controlSize(.small)
                }
                if let answer = request.answer, request.status == "done" {
                    Button("Copy answer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var onShowAvailable: Bool { request.status != "failed" || request.answer != nil }

    private func approval(_ a: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(a.tool) needs your OK").font(.system(size: 12, weight: .semibold))
            ScrollView {
                Text(a.detail.isEmpty ? a.summary : a.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                TextField("Or tell Claude what to do instead…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(a, allow: false) }
                if typed.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Allow") { send(a, allow: true) }.buttonStyle(.borderedProminent)
                    Button("Deny") { send(a, allow: false) }
                } else {
                    Button("Send instead") { send(a, allow: false) }.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(hex: 0xF0B04B, opacity: 0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func send(_ a: PendingApproval, allow: Bool) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        onAnswer(request.id, a.id, allow && text.isEmpty, text.isEmpty ? nil : text)
        answered.insert(a.id)
        typed = ""
    }

    private var icon: String {
        switch request.status {
        case "waiting": return "hand.raised.fill"
        case "running": return "hourglass"
        case "failed": return "xmark.circle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch request.status {
        case "waiting": return Color(hex: 0xD2832A)
        case "running": return .secondary
        case "failed": return .red
        default: return .green
        }
    }
}
