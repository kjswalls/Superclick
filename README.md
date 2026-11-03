# Superclick

Your AI agents, attached to your cursor. Superclick (code name; working product name "Cursor Companion") is a Mac presence layer that summons your existing agents (Claude Code first) with a global hotkey, captures what you're looking at, routes each request to the right project session, and brings results back where you're working.

- **[SPEC.md](SPEC.md)** is the product and build brief.
- **[DECISIONS.md](DECISIONS.md)** records each choice made and why.

## Status

| Milestone | State |
|---|---|
| M0: Clickable mockup | Ready for review |
| M1–M5 | Not started. Stack (SwiftUI vs Tauri) to be proposed after M0 review |

## M0: clickable mockup

Open `mockup/index.html` in any modern browser. No install or build step.

```sh
open mockup/index.html          # macOS
# or serve it: python3 -m http.server -d mockup 8000
```

Pick a flow at the top and follow the steps in the left panel:

1. **Point and ask:** select a stack trace in the editor, press ⌥Space, send, see "→ shop", then Paste here / Copy / Open session / Reply.
2. **Ask without a project:** select a blog paragraph, send "save this for the game idea…", tap the routing chip to reroute. "Try a vague request" shows the low-confidence fallback.
3. **Long task:** ask shop to fix a failing test, walk away, approve from the notification, come back, open the menu-bar badge for the "while you were away" card.

Keys: ⌥Space summons, Enter sends, Esc dismisses, ⌘Enter pastes. All data is fake.

## macOS permissions (from M1)

The real app will need two permissions, granted in **System Settings → Privacy & Security**:

- **Accessibility:** to read the focused app, window title and selected text, and to paste results back.
- **Screen Recording:** to capture a screenshot of the active window when you summon.

Capture only happens when you summon; there is no background recording. Setup steps will be filled in here when M1 lands.
