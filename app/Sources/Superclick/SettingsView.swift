import AppKit
import SuperclickCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
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
