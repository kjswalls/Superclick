# Superclick

Your AI agents, attached to your cursor. Superclick (code name; working product name "Cursor Companion") is a Mac presence layer that summons your existing agents (Claude Code first) with a global hotkey, captures what you're looking at, routes each request to the right project session, and brings results back where you're working.

- **[SPEC.md](SPEC.md)** is the product and build brief.
- **[DECISIONS.md](DECISIONS.md)** records each choice made and why.

## Status

| Milestone | State |
|---|---|
| M0: Clickable mockup | Done |
| M1: Summon + See | Built; first run and the page-text check on a Mac pending |
| M2: Ask Claude Code | Built (daemon + Claude Code adapter, streamed replies, approvals, Paste here); first run on a Mac pending |
| M3–M5 | Not started |

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

## M1: Summon + See

Needs macOS 15 or later and Xcode 16 or later (Xcode 26 for Liquid Glass; on older SDKs the bubble uses a blur material).

```sh
scripts/build-app.sh --open     # builds build/Superclick.app and launches it
```

Superclick lives in the menu bar. On first launch it opens a permissions window (below). Then press **⌥Space** anywhere: the bubble opens at your pointer with chips for what it captured. Remove any chip you don't want to send, click the page chip to switch between "around selection" and "full page", type a request and press **Enter**. With the daemon running (below), Enter asks Claude Code and the answer streams into the bubble; without it, Enter copies the request and its context to the clipboard. **Esc** or a click elsewhere closes it.

If ⌥Space does nothing, another app (Raycast, Alfred, an input method) probably owns it: the menu-bar icon shows an orange dot, and Settings offers ⌃⌥Space, ⇧⌥Space or ⇧⌘Space.

**Signing.** `build-app.sh` signs ad hoc unless you set `SIGN_IDENTITY` to a certificate from `security find-identity -v -p codesigning`. With an ad hoc signature, macOS forgets the Accessibility permission on every rebuild: turn Superclick off and on again in Accessibility. An Apple Development certificate avoids that.

### macOS permissions

Granted in **System Settings → Privacy & Security**. The onboarding window (menu bar → Permissions…) shows the status of each and opens the right pane.

- **Accessibility** (required): reads the front app and window, the document or folder it shows, your selection, and a web page's text including what's scrolled off screen.
- **Screen Recording** (optional): a screenshot of the front window. macOS applies it after Superclick restarts; the onboarding window has a Restart button. Screenshots can be turned off in Settings.

Capture only happens when you summon; there is no background recording. Captured screenshots are kept in `~/Library/Application Support/Superclick/Captures` and deleted after a day.

### The page-text check

This was the M1 spike. It checks that Superclick can read a whole web page, including what's off screen, in under 300 ms.

1. Open a long article (a long Wikipedia page works) in Safari. Don't scroll down. Select a sentence.
2. Press ⌥Space, then menu bar → **Page-text check…**. It shows each step's timing with PASS or SLOW, and the page's first and last lines.
3. It passes when "Ends with" matches the article's last lines, the full read is under 300 ms, and the URL, selection and headings came through.
4. Repeat in Chrome (and Arc or Edge if you use them). **Copy report** puts the numbers on the clipboard.

The same check runs from Terminal, using the same capture code. It saves the full and trimmed text next to you:

```sh
cd app && swift run pagetext                 # then switch to the browser within 3 s
swift run pagetext --app com.google.Chrome   # or target a browser directly
swift run pagetext --dump                    # also list the window's AX attributes
```

## M2: Ask Claude Code

The daemon runs the Claude Code sessions. Start it once in a Terminal and leave it running:

```sh
claude                                       # once, if you haven't signed in to Claude Code on this Mac
cd daemon && bun install && bun run start
bun test                                     # tests
```

It uses your Claude Code sign-in; there's no API key to set. The bubble's footer says "daemon on" when it's connected (it retries every 5 s).

**What to try**

1. In Terminal, `cd` into one of your repos, select an error message, press ⌥Space and ask "what's wrong?". The routing chip should name the repo: requests go to the terminal's folder, or the open file's folder, widened to its git root.
2. In Safari, select a paragraph and ask "rewrite this shorter". With no project in the context it goes to **Inbox** (a session in your home folder).
3. When the answer is done, press **⌘↵** (Paste here): the bubble hides, the answer is pasted where your cursor was, the pointer glows, and your clipboard is put back.
4. Ask for something that writes, like "add a test for this". Claude Code asks before running anything but local reads (Read, Glob, Grep). The approval card has **Allow**, **Deny**, or a box to tell it what to do instead.
5. Press **Esc** while it's working: the request keeps going, and the menu-bar icon shows a dot when the answer (or an approval) is waiting. Menu bar → **Show last answer** brings it back.
6. Reply in the same bubble to continue: each project keeps one session, resumed across requests.

The daemon listens on `127.0.0.1:47811` only and accepts the app only with the token in `~/Library/Application Support/Superclick/daemon.token` (owner-only permissions, re-checked at start). Connections from web pages, which always carry an Origin header, are refused. It logs the shape of each request (sizes, counts), never its text.

### Layout

| Path | What |
|---|---|
| `app/Sources/SuperclickCore` | Pure logic: context bundle, secret redaction, blocklist, page excerpt, prompt text, chip overflow. Unit tested (`swift test`). |
| `app/Sources/SuperclickCapture` | Accessibility and ScreenCaptureKit capture, shared by the app and `pagetext`. |
| `app/Sources/Superclick` | The menu-bar app: hotkey, bubble, glow, onboarding, settings, page-text check window. |
| `app/Sources/pagetext` | The page-text check as a command-line tool. |
| `daemon/src/agents` | The agent adapter interface and the Claude Code adapter (Claude Agent SDK). |
| `daemon/src/sessions.ts` | Routing a request to a project session. |
| `daemon/` | TypeScript daemon on Bun: WebSocket server, protocol, request store. |
