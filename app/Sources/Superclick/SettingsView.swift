import AppKit
import ServiceManagement
import SuperclickCore
import SwiftUI

/// The daemon as a login item (M4): registered with SMAppService from the
/// LaunchAgent plist that build-app.sh puts inside the app.
@MainActor
final class DaemonLoginItem: ObservableObject {
    static let shared = DaemonLoginItem()
    private let service = SMAppService.agent(plistName: "dev.superclick.daemon.plist")
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?

    /// False when the app was built without Bun, so there's no daemon inside it.
    var isBundled: Bool {
        FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/superclick-daemon").path)
    }

    init() { refresh() }

    func refresh() { status = service.status }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func set(_ on: Bool) {
        error = nil
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var loginItem = DaemonLoginItem.shared

    var body: some View {
        Form {
            Section("Daemon") {
                if loginItem.isBundled {
                    Toggle("Start the daemon at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                    if loginItem.status == .requiresApproval {
                        HStack {
                            Text("macOS needs you to allow it in Login Items.").font(.caption)
                            Button("Open Login Items") { loginItem.openLoginItems() }.controlSize(.small)
                        }
                    }
                    if let e = loginItem.error {
                        Text(e).font(.caption).foregroundStyle(.orange)
                    }
                    Text("The daemon runs your Claude Code sessions and keeps working when the bubble is closed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This build has no daemon inside it (Bun wasn't installed when it was built). Run it with `bun run start` in daemon/.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Toggle("When a closed bubble needs your OK", isOn: $store.value.notifyForApprovals)
                Toggle("When a closed bubble's answer is ready", isOn: $store.value.notifyWhenDone)
                Text("You can Allow, Deny, or type what to do instead right in the notification.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                Picker("Summon", selection: $store.value.hotkey) {
                    ForEach(HotkeyPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("If the bubble doesn't open, another app (Raycast, Alfred, an input method) may own the shortcut. Pick another.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Page text") {
                Toggle("Send the full page by default", isOn: $store.value.fullPageByDefault)
                Text("Otherwise Superclick sends the page outline and the text around your selection. You can switch for one request by clicking the page chip.")
                    .font(.caption).foregroundStyle(.secondary)
                EditableList(
                    title: "Always send the full page on", placeholder: "example.com",
                    items: $store.value.fullPageSites, normalize: Domain.normalize)
            }

            Section("Capture") {
                Toggle("Include a screenshot of the window", isOn: $store.value.captureScreenshot)
            }

            Section("Never capture") {
                EditableList(
                    title: "Apps (bundle IDs)", placeholder: "com.example.App",
                    items: $store.value.blocklist.apps,
                    normalize: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) },
                    suggestions: runningApps)
                EditableList(
                    title: "Sites", placeholder: "bank.example",
                    items: $store.value.blocklist.sites, normalize: Domain.normalize)
                Button("Restore default blocklist") { store.value.blocklist = .standard }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { loginItem.refresh() }
    }

    private var runningApps: [Suggestion] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { Suggestion(name: app.localizedName ?? $0, value: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct Suggestion: Identifiable {
    var name: String
    var value: String
    var id: String { value }
}

/// A list you can add to by typing, or by picking a suggestion.
private struct EditableList: View {
    let title: String
    let placeholder: String
    @Binding var items: [String]
    var normalize: (String) -> String?
    var suggestions: [Suggestion] = []
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button { items.removeAll { $0 == item } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(placeholder, text: $draft).onSubmit(add)
                if !suggestions.isEmpty {
                    Menu("Running apps") {
                        ForEach(suggestions) { s in
                            Button(s.name) { append(s.value) }
                        }
                    }
                    .fixedSize()
                }
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        guard let v = normalize(draft) else { return }
        append(v)
        draft = ""
    }

    private func append(_ v: String) {
        if !items.contains(v) { items.append(v) }
    }
}
