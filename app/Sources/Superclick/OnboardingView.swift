import SwiftUI

/// Permissions onboarding: what each permission is for, its live status, and
/// a button straight to the right pane of System Settings.
struct OnboardingView: View {
    @ObservedObject var permissions = Permissions.shared
    @ObservedObject var settings = SettingsStore.shared
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Rainbow.angular(0))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Superclick").font(.system(size: 20, weight: .semibold))
                    Text("Your AI agents, attached to your cursor.").foregroundStyle(.secondary)
                }
            }

            Text("Press **\(settings.value.hotkey.label)** anywhere to open the bubble at your pointer. Superclick only looks at your screen when you press it. There's no background recording, and every captured item shows as a chip you can remove before sending.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Reads the app and window you're in, your selection, and a web page's text, including what's scrolled off screen.",
                    granted: permissions.accessibility,
                    action: permissions.requestAccessibility)
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Takes a screenshot of the front window when you summon. Optional; you can turn screenshots off in Settings.",
                    granted: permissions.screenRecording,
                    action: permissions.requestScreenRecording)
            }

            if permissions.screenRecordingNeedsRelaunch && !permissions.screenRecording {
                HStack {
                    Text("macOS applies Screen Recording after Superclick restarts.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Superclick") { Permissions.relaunch() }
                }
                .font(.callout)
            }

            Text("If you rebuild the app and it stops seeing context, turn Superclick off and on again in Accessibility. macOS ties the permission to each build's signature.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(permissions.accessibility ? "Done" : "Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .padding(.top, 12)
        .frame(minWidth: 480, minHeight: 440)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: action)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
