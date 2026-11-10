import Foundation
import SuperclickCore

/// What the daemon reports about one request.
enum ReplyEvent {
    case accepted(project: String?, agent: String?, reason: String?, note: String)
    case delta(String)
    case tool(String)
    case approval(id: String, tool: String, summary: String)
    case done(String)
    case error(String)
}

/// Talks to the local daemon over its WebSocket (DECISIONS: Swift app plus a
/// TypeScript daemon). The daemon runs the agent sessions and streams replies
/// back. Without it, the bubble still copies the request with its context.
@MainActor
final class DaemonClient: ObservableObject {
    enum State: Equatable {
        case notRunning, connecting, connected(version: String)

        var label: String {
            switch self {
            case .notRunning: return "· daemon off"
            case .connecting: return "· connecting…"
            case .connected: return "· daemon on"
            }
        }

        var help: String {
            switch self {
            case .notRunning:
                return "The Superclick daemon isn't running, so Enter copies the request with its context instead of asking Claude Code. Start it with `bun run start` in daemon/."
            case .connecting: return "Connecting to the Superclick daemon…"
            case .connected(let v): return "Connected to the Superclick daemon \(v)."
            }
        }
    }

    static let port = 47811

    @Published private(set) var state: State = .notRunning
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)
    private var retry: Task<Void, Never>?
    private var handlers: [String: (ReplyEvent) -> Void] = [:]

    /// The daemon writes a random token here (mode 0600) and only accepts
    /// connections that present it, so other local processes and web pages can't talk to it.
    static var tokenURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Superclick/daemon.token")
    }

    func connect() {
        retry?.cancel()
        guard let token = try? String(contentsOf: Self.tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            state = .notRunning
            scheduleRetry()
            return
        }
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(Self.port)/v1")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3
        let t = session.webSocketTask(with: req)
        task = t
        state = .connecting
        t.resume()
        send(["type": "hello", "client": "superclick-mac", "version": Self.appVersion])
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .failure:
                    self.task = nil
                    self.state = .notRunning
                    self.failAll("Lost the connection to the Superclick daemon.")
                    self.scheduleRetry()
                case .success(let message):
                    if case .string(let s) = message { self.handle(s) }
                    self.receive(on: t)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if type == "welcome" {
            state = .connected(version: obj["version"] as? String ?? "?")
            return
        }
        guard let id = obj["id"] as? String, let handler = handlers[id] else { return }
        let str = { (k: String) in obj[k] as? String ?? "" }
        let event: ReplyEvent?
        switch type {
        case "request.accepted":
            let r = obj["route"] as? [String: Any]
            event = .accepted(project: r?["project"] as? String, agent: r?["agent"] as? String,
                              reason: r?["reason"] as? String, note: str("note"))
        case "reply.delta": event = .delta(str("text"))
        case "reply.tool": event = .tool(str("summary"))
        case "approval.needed": event = .approval(id: str("approvalId"), tool: str("tool"), summary: str("summary"))
        case "reply.done": event = .done(str("text"))
        case "reply.error": event = .error(str("message"))
        default: event = nil
        }
        guard let event else { return }
        handler(event)
        if case .done = event { handlers[id] = nil }
        if case .error = event { handlers[id] = nil }
    }

    /// Drops every running request with an error, so no bubble waits forever.
    private func failAll(_ message: String) {
        let hs = handlers
        handlers = [:]
        for h in hs.values { h(.error(message)) }
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Sends the request and what's left of its context to the agent. Returns
    /// the request id, or nil when the daemon isn't connected.
    @discardableResult
    func sendRequest(text: String, prompt: String, bundle: ContextBundle, fullPage: Bool,
                     onEvent: @escaping (ReplyEvent) -> Void) -> String? {
        guard isConnected,
              let bundleData = try? Self.encoder.encode(bundle),
              let bundleJSON = try? JSONSerialization.jsonObject(with: bundleData) else { return nil }
        let id = UUID().uuidString
        handlers[id] = onEvent
        send(["type": "request", "id": id, "text": text, "prompt": prompt, "fullPage": fullPage, "context": bundleJSON])
        return id
    }

    func answerApproval(id: String, allow: Bool, message: String?) {
        var obj: [String: Any] = ["type": "approval.answer", "approvalId": id, "allow": allow]
        if let message, !message.isEmpty { obj["message"] = message }
        send(obj)
    }

    func cancel(requestID: String) {
        send(["type": "request.cancel", "id": requestID])
    }

    private func send(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
