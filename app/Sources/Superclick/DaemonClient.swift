import Foundation
import SuperclickCore

/// Where the coordinator sent a request, and why (M3).
struct RouteInfo: Equatable {
    var projectID: String
    var project: String
    var agent: String
    var reason: String
    /// explicit, path, rule, recent, model or fallback.
    var step: String
    var confidence: Double?
    /// Low confidence: projects to offer with one tap.
    var ask: [ProjectRef]
}

/// A request's state as the daemon holds it, sent after the app reconnects.
struct RunSnapshot {
    var route: RouteInfo?
    var text: String
    var tools: [String]
    var approvals: [PendingApproval]
    /// running, done or failed.
    var status: String
    var final: String?
    var error: String?
}

struct ProjectRef: Equatable, Identifiable, Hashable {
    var id: String
    var name: String
}

struct ProjectRule: Equatable, Identifiable {
    var id: Int
    var kind: String
    var pattern: String
    var source: String
}

/// A project as the daemon's registry holds it.
struct ProjectInfo: Equatable, Identifiable {
    static let inboxID = "inbox"
    var id: String
    var name: String
    var paths: [String]
    var description: String
    var summary: String
    var updatedAt: Date?
    var rules: [ProjectRule]
    var isInbox: Bool { id == Self.inboxID }
}

/// What the daemon reports about one request.
enum ReplyEvent {
    /// Sent first on every run, and again when the request is moved to another project.
    case accepted(route: RouteInfo?, note: String)
    case delta(String)
    case tool(String)
    case approval(id: String, tool: String, summary: String, detail: String)
    /// The daemon no longer knew that approval (it timed out, or the daemon restarted), so it was denied.
    case approvalExpired(String)
    /// After a reconnect: the request's state as the daemon has it.
    case resync(RunSnapshot)
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
    /// Every project, Inbox last. Pushed by the daemon whenever one changes.
    @Published private(set) var projects: [ProjectInfo] = []
    /// The last problem the daemon reported that isn't tied to a request (shown in Projects).
    @Published var lastError: String?
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)
    private var retry: Task<Void, Never>?
    private var handlers: [String: (ReplyEvent) -> Void] = [:]
    /// Requests that were running when the connection dropped, waiting for the daemon's sync.
    private var awaitingSync: Set<String> = []
    private var orphanTimer: Task<Void, Never>?

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
                    // Keep running requests: the daemon keeps working, and the sync after a
                    // reconnect brings them up to date. Give up on them if it stays away.
                    self.awaitingSync.formUnion(self.handlers.keys)
                    self.orphanTimer?.cancel()
                    self.orphanTimer = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(30))
                        guard let self, !Task.isCancelled, !self.isConnected else { return }
                        self.failAll("Lost the connection to the Superclick daemon.")
                    }
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
        switch type {
        case "welcome":
            state = .connected(version: obj["version"] as? String ?? "?")
            return
        case "projects":
            projects = (obj["projects"] as? [[String: Any]] ?? []).compactMap(Self.project)
            return
        case "error":
            lastError = obj["detail"] as? String ?? obj["error"] as? String
            return
        case "sync":
            orphanTimer?.cancel()
            let runs = (obj["runs"] as? [[String: Any]] ?? [])
            var seen = Set<String>()
            for r in runs {
                guard let id = r["id"] as? String, let handler = handlers[id] else { continue }
                seen.insert(id)
                let snap = Self.snapshot(r)
                handler(.resync(snap))
                if snap.status != "running" { handlers[id] = nil }
            }
            for id in awaitingSync where !seen.contains(id) {
                handlers.removeValue(forKey: id)?(.error("This request was lost when the daemon restarted. Ask again."))
            }
            awaitingSync = []
            return
        default:
            break
        }
        guard let id = obj["id"] as? String, let handler = handlers[id] else { return }
        let str = { (k: String) in obj[k] as? String ?? "" }
        let event: ReplyEvent?
        switch type {
        case "request.accepted":
            event = .accepted(route: (obj["route"] as? [String: Any]).flatMap(Self.route), note: str("note"))
        case "reply.delta": event = .delta(str("text"))
        case "reply.tool": event = .tool(str("summary"))
        case "approval.needed":
            event = .approval(id: str("approvalId"), tool: str("tool"), summary: str("summary"),
                              detail: obj["detail"] as? String ?? str("summary"))
        case "approval.expired": event = .approvalExpired(str("approvalId"))
        case "reply.done": event = .done(str("text"))
        case "reply.error": event = .error(str("message"))
        default: event = nil
        }
        guard let event else { return }
        handler(event)
        if case .done = event { handlers[id] = nil }
        if case .error = event { handlers[id] = nil }
    }

    private static func route(_ r: [String: Any]) -> RouteInfo? {
        guard let id = r["projectId"] as? String, let name = r["project"] as? String else { return nil }
        let ask = (r["ask"] as? [[String: Any]] ?? []).compactMap { a -> ProjectRef? in
            guard let id = a["id"] as? String, let name = a["name"] as? String else { return nil }
            return ProjectRef(id: id, name: name)
        }
        return RouteInfo(projectID: id, project: name, agent: r["agent"] as? String ?? "Claude Code",
                         reason: r["reason"] as? String ?? "", step: r["step"] as? String ?? "",
                         confidence: (r["confidence"] as? NSNumber)?.doubleValue, ask: ask)
    }

    private static func snapshot(_ r: [String: Any]) -> RunSnapshot {
        let approvals = (r["approvals"] as? [[String: Any]] ?? []).compactMap { a -> PendingApproval? in
            guard let id = a["approvalId"] as? String else { return nil }
            return PendingApproval(id: id, tool: a["tool"] as? String ?? "", summary: a["summary"] as? String ?? "",
                                   detail: a["detail"] as? String ?? "")
        }
        return RunSnapshot(route: (r["route"] as? [String: Any]).flatMap(Self.route), text: r["text"] as? String ?? "",
                           tools: r["tools"] as? [String] ?? [], approvals: approvals,
                           status: r["status"] as? String ?? "running", final: r["final"] as? String, error: r["error"] as? String)
    }

    private static func project(_ p: [String: Any]) -> ProjectInfo? {
        guard let id = p["id"] as? String, let name = p["name"] as? String else { return nil }
        let rules = (p["rules"] as? [[String: Any]] ?? []).compactMap { r -> ProjectRule? in
            guard let id = (r["id"] as? NSNumber)?.intValue, let kind = r["kind"] as? String,
                  let pattern = r["pattern"] as? String else { return nil }
            return ProjectRule(id: id, kind: kind, pattern: pattern, source: r["source"] as? String ?? "user")
        }
        let updated = (p["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ProjectInfo(id: id, name: name, paths: p["paths"] as? [String] ?? [],
                           description: p["description"] as? String ?? "", summary: p["summary"] as? String ?? "",
                           updatedAt: updated, rules: rules)
    }

    /// Drops every running request with an error, so no bubble waits forever.
    private func failAll(_ message: String) {
        let hs = handlers
        handlers = [:]
        awaitingSync = []
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
    func sendRequest(text: String, prompt: String, bundle: ContextBundle, fullPage: Bool, project: String? = nil,
                     onEvent: @escaping (ReplyEvent) -> Void) -> String? {
        guard isConnected,
              let bundleData = try? Self.encoder.encode(bundle),
              let bundleJSON = try? JSONSerialization.jsonObject(with: bundleData) else { return nil }
        let id = UUID().uuidString
        handlers[id] = onEvent
        var msg: [String: Any] = ["type": "request", "id": id, "text": text, "prompt": prompt, "fullPage": fullPage, "context": bundleJSON]
        if let project { msg["project"] = project }
        send(msg)
        return id
    }

    /// Moves a request to another project: an existing one by id, or by a typed name (new if no project has it).
    /// The request's events keep coming to the same handler, starting with a new `accepted`.
    func reroute(requestID: String, projectID: String?, name: String?, onEvent: @escaping (ReplyEvent) -> Void) {
        var msg: [String: Any] = ["type": "request.reroute", "id": requestID]
        if let projectID { msg["project"] = projectID }
        if let name, !name.isEmpty { msg["name"] = name }
        handlers[requestID] = onEvent
        send(msg)
    }

    func refreshProjects() { send(["type": "projects.list"]) }

    func saveProject(id: String?, name: String, paths: [String]? = nil, description: String? = nil) {
        var p: [String: Any] = ["name": name]
        if let id { p["id"] = id }
        if let paths { p["paths"] = paths }
        if let description { p["description"] = description }
        lastError = nil
        send(["type": "projects.save", "project": p])
    }

    func removeProject(id: String) { send(["type": "projects.remove", "id": id]) }

    func saveRule(projectID: String, kind: String, pattern: String) {
        lastError = nil
        send(["type": "rules.save", "projectId": projectID, "kind": kind, "pattern": pattern])
    }

    func removeRule(id: Int) { send(["type": "rules.remove", "id": id]) }

    func answerApproval(id: String, requestID: String?, allow: Bool, message: String?) {
        var obj: [String: Any] = ["type": "approval.answer", "approvalId": id, "allow": allow]
        if let requestID { obj["id"] = requestID }
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
