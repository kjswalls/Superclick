import AppKit
import SwiftUI

/// The coordinator's project registry (M3): each project's folders, its
/// one-line description (the router reads it), its running summary, and its
/// URL and app rules, including the ones learned from reroutes.
struct ProjectsView: View {
    @ObservedObject var daemon: DaemonClient
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !daemon.isConnected {
                Label("The daemon isn't running. Start it with `bun run start` in daemon/ to see and edit projects.",
                      systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
            if let e = daemon.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            Form {
                Section {
                    HStack {
                        Button("Add project folder…", action: addFolder)
                        Spacer()
                        TextField("Or a project without a folder", text: $newName)
                            .onSubmit(addNamed)
                            .frame(maxWidth: 220)
                        Button("Add", action: addNamed)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Requests from a file or terminal in a project's folder go to it. A git repository you work in becomes a project by itself. Type @name in the bubble to pick one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(daemon.projects) { p in
                    ProjectRow(project: p, daemon: daemon)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { daemon.refreshProjects() }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        daemon.saveProject(id: nil, name: url.lastPathComponent, paths: [url.path])
    }

    private func addNamed() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        daemon.saveProject(id: nil, name: name)
        newName = ""
    }
}

private struct ProjectRow: View {
    let project: ProjectInfo
    @ObservedObject var daemon: DaemonClient
    @State private var name = ""
    @State private var description = ""
    @State private var rulePattern = ""
    @State private var ruleKind = "url"
    @State private var confirmRemove = false

    var body: some View {
        Section {
            HStack {
                TextField("Name", text: $name)
                    .font(.headline)
                    .disabled(project.isInbox)
                    .onSubmit(save)
                Spacer()
                if !project.isInbox {
                    Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove this project. Its folder and files stay.")
                }
            }
            TextField("One line on what it's about (helps routing)", text: $description, axis: .vertical)
                .lineLimit(1...3)
                .onSubmit(save)
            HStack(alignment: .firstTextBaseline) {
                Text(project.paths.first.map(Self.tilde) ?? "No folder")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !project.isInbox {
                    Button("Change folder…", action: changeFolder).buttonStyle(.borderless)
                }
                if let f = project.paths.first {
                    Button("Show") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: f) }
                        .buttonStyle(.borderless)
                }
            }
            if !project.summary.isEmpty {
                Text(project.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !project.isInbox {
                ForEach(project.rules) { r in
                    HStack {
                        Image(systemName: r.kind == "url" ? "globe" : "app")
                            .foregroundStyle(.secondary)
                        Text(r.pattern).font(.system(.callout, design: .monospaced))
                        if r.source == "reroute" {
                            Text("learned").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { daemon.removeRule(id: r.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Picker("", selection: $ruleKind) {
                        Text("Site").tag("url")
                        Text("App").tag("app")
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField(ruleKind == "url" ? "github.com/me/shop/*" : "com.figma.Desktop", text: $rulePattern)
                        .onSubmit(addRule)
                    Button("Add rule", action: addRule)
                        .disabled(rulePattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: project) { _, _ in load() }
        .confirmationDialog("Remove \(project.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { daemon.removeProject(id: project.id) }
        } message: {
            Text("Its rules go too. The folder and its files stay where they are.")
        }
    }

    private func load() {
        name = project.name
        description = project.description
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != project.name || description != project.description else { return }
        daemon.saveProject(id: project.id, name: n, description: description)
    }

    private func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        daemon.saveProject(id: project.id, name: project.name, paths: [url.path])
    }

    private func addRule() {
        let p = rulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        daemon.saveRule(projectID: project.id, kind: ruleKind, pattern: p)
        rulePattern = ""
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
