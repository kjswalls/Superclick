# Superclick

Your AI agents, attached to your cursor. Superclick (code name; working product name "Cursor Companion") is a Mac presence layer that summons your existing agents (Claude Code first) with a global hotkey, captures what you're looking at, routes each request to the right project session, and brings results back where you're working.

- **[SPEC.md](SPEC.md)** is the product and build brief.
- **[DECISIONS.md](DECISIONS.md)** records each choice made and why.

## Status

| Milestone | State |
|---|---|
| M0: Clickable mockup | Done |
| M1: Summon + See | Built and reviewed; first run and the page-text check on a Mac pending |
| M2: Ask Claude Code | Built and reviewed (daemon + Claude Code adapter, streamed replies, approvals, Paste here); first run on a Mac pending |
| M3: Coordinator | Built and reviewed (projects, routing steps 1–6, one-tap reroute that learns, summaries); first run pending |
| M4: Follow (desktop) | Built and reviewed (notifications with Allow/Deny/reply, badge, "While you were away", daemon at login); first run pending |
| M5: Context MCP server | Built and reviewed (`what_am_i_looking_at`, `recent_context`); first run pending |

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
2. In Safari, select a paragraph and ask "rewrite this shorter". With no project in the context it goes to **Inbox** (see M3 for how routing works now).
3. When the answer is done, press **⌘↵** (Paste here): the bubble hides, the answer is pasted where your cursor was, the pointer glows, and your clipboard is put back.
4. Ask for something that writes, like "add a test for this". Claude Code asks before running anything but local reads (Read, Glob, Grep). The approval card has **Allow**, **Deny**, or a box to tell it what to do instead.
5. Press **Esc** while it's working: the request keeps going, and the menu-bar icon shows a dot when the answer (or an approval) is waiting. Menu bar → **Show last answer** brings it back.
6. Reply in the same bubble to continue: each project keeps one session, resumed across requests.

The daemon listens on `127.0.0.1:47811` only and accepts the app only with the token in `~/Library/Application Support/Superclick/daemon.token` (owner-only permissions, re-checked at start). Connections from web pages, which always carry an Origin header, are refused. It logs the shape of each request (sizes, counts), never its text.

## M3: Projects and routing

Every request goes to a project, and each project has one long-lived Claude Code session in its folder. Menu bar → **Projects…** lists them: folders, a one-line description (the router reads it), the running summary, and site or app rules.

Routing tries these in order and the chip in the bubble says which one won (hover it for why):

1. **You picked it**: type `@shop` in the bubble, or reply in the same bubble.
2. **Path**: the terminal's folder or the open file sits in a project's folder. A git repo you work in becomes a project by itself (never your home folder, and a repo you removed stays removed).
3. **Rule**: a site rule like `github.com/me/shop/*`, or an app rule like `com.figma.Desktop`.
4. **Recent**: same app and same window as your last request in the past 5 minutes, or worded like a follow-up ("and also…", "try again").
5. **Model**: a small fast model picks from the projects' descriptions and summaries.
6. **Inbox**: when it isn't sure, it goes to Inbox and the bubble offers the likely project with one tap.

Click the chip → **Move to** to send it elsewhere. Moving teaches a narrow site rule (a repo, a document, a section of a site; never mail, chat or localhost), shown as "learned" in Projects, where you can delete it. Picking from the "shop or Inbox?" offer teaches nothing.

New projects without a folder get one in `~/Library/Application Support/Superclick/Projects/<name>`; Inbox lives in `…/Superclick/Inbox`.

**What to try**: add a repo in Projects with a description, then ask from a Safari page about that project and see whether it routes there (step 5). Move a request from a GitHub page and check the learned rule.

## M4: Follow long tasks

- **Notifications** (macOS Notification Center, never on the cursor): when a closed bubble needs an approval you get Allow, Deny, or Reply (typed instruction) right in the notification; when it finishes you get "answer ready". Toggle both in Settings → Notifications.
- **Menu bar**: a count next to the icon for answers and approvals waiting, a row per running or waiting request with Show and Stop, and **While you were away…**: one card per project with what ran, what changed, and what's waiting, with approvals you can answer there.
- **Restarts**: if the app quits or reconnects, requests the daemon is still running reappear in the menu.
- **Daemon at login**: `scripts/build-app.sh` compiles the daemon (needs Bun) into the app with Claude Code inside it. Settings → Daemon → **Start the daemon at login** registers it with macOS (System Settings → General → Login Items shows it). Stop any `bun run start` copy first, since both want port 47811.

**What to try**: ask for something long ("refactor X and run the tests"), press Esc, switch apps, and answer the approval from the notification. Then open While you were away….

## M5: The agent asks for context itself

Every Claude Code session gets two Superclick tools:

- `what_am_i_looking_at` takes a fresh capture of the front window (same blocklist, private-window and redaction rules as a summon; screenshot optional and downscaled). It **always asks first**, with an approval card, and the menu-bar icon flashes an eye and the menu shows "Claude Code captured … at …" afterwards.
- `recent_context` reads the rest of what your recent requests captured (full page, selection, outline) without asking, since you already sent it.

**What to try**: summon over a long article, ask "summarize the first section", then follow up "now read the rest" and watch it call `recent_context`. Ask "what's on my screen now?" after switching windows to see the capture approval.

## Building the app with the daemon inside

```sh
scripts/build-app.sh --open     # needs Xcode and Bun; SIGN_IDENTITY keeps permissions across rebuilds
```

### Layout

| Path | What |
|---|---|
| `app/Sources/SuperclickCore` | Pure logic: context bundle, secret redaction, blocklist, page excerpt, prompt text, chip overflow. Unit tested (`swift test`). |
| `app/Sources/SuperclickCapture` | Accessibility and ScreenCaptureKit capture, shared by the app and `pagetext`. |
| `app/Sources/Superclick` | The menu-bar app: hotkey, bubble, glow, onboarding, settings, page-text check window. |
| `app/Sources/pagetext` | The page-text check as a command-line tool. |
| `daemon/src/agents` | The agent adapter interface and the Claude Code adapter (Claude Agent SDK). |
| `daemon/src/sessions.ts` | One long-lived session per project, with its running summary. |
| `daemon/src/projects.ts`, `coordinator.ts` | Project registry, rules, and the routing steps. |
| `daemon/src/journal.ts` | The event log behind "While you were away". |
| `daemon/src/contextMcp.ts` | The `what_am_i_looking_at` and `recent_context` tools. |
| `daemon/bin` | Compiled-daemon entry points that embed Claude Code. |
| `daemon/` | TypeScript daemon on Bun: WebSocket server, protocol, request store. |
