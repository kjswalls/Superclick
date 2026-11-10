import Foundation
import SuperclickCore

/// Talks to the local daemon over its WebSocket (DECISIONS: Swift app plus a
/// TypeScript daemon). In M1 the daemon only acknowledges and holds requests
/// with their context; agents run there from M2. The bubble works without it.
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
                return "The Superclick daemon isn't running. Start it with `bun run start` in daemon/. The bubble still works without it."
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
        }
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// Hands the request and what's left of its context to the daemon.
    func sendRequest(text: String, bundle: ContextBundle, fullPage: Bool) {
        guard case .connected = state,
              let bundleData = try? Self.encoder.encode(bundle),
              let bundleJSON = try? JSONSerialization.jsonObject(with: bundleData) else { return }
        send(["type": "request", "id": UUID().uuidString, "text": text, "fullPage": fullPage, "context": bundleJSON])
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
