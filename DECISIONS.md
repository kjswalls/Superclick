# Decisions

A running log of choices made while building Superclick, and why. Newest at the bottom.

## 2026-11-03 · Code name is Superclick; product name still open

The brief calls the product "Cursor Companion" as a working name. Kirby set the code name to **Superclick**, and the final product name is undecided. Code, docs and the mockup use Superclick. Revisit when naming and pricing (an open question in SPEC.md) get decided.

## 2026-11-03 · M0 mockup is a single static HTML file

`mockup/index.html` is plain HTML, CSS and JavaScript with no build step and no dependencies beyond Google Fonts.

- **Why:** M0 must exist before the stack decision (SwiftUI vs Tauri), so it should not presuppose either. A static page opens anywhere, is easy to share as a link, and is cheap to throw away.
- **Consequence:** none of the mockup code is meant to be reused. If Tauri wins, the visual design and copy carry over, not the code.

## 2026-11-03 · Mockup design choices worth keeping (or overturning) in M1

These are product guesses the spec doesn't pin down. They are cheap to change now.

- **Bubble layout, top to bottom:** context chips → request → routing chip → reply → actions. The context chip is shown *before* you send, so you can remove items (the visible-capture rule).
- **Secret redaction is visible** as its own chip ("1 secret redacted") rather than happening silently.
- **The routing chip has a "Why?" link** that shows which of the six routing steps matched and why the earlier ones were skipped. This mirrors the routing log the coordinator must keep.
- **A reroute immediately proposes a rule** in a toast with Undo, per "reroutes become new rules".
- **Low-confidence fallback** asks "game idea or Inbox?" inside the bubble with Inbox pre-selected as the default.
- **Dangerous actions in notifications** show a warning and no Approve button; the "while you were away" card is where you review the diff and approve.
- **"While you were away" cards** use three fixed sections per session: What ran, What changed, Waiting on you. The Inbox card is where "make it a project?" suggestions appear.
- **The example prompt auto-types** into the bubble so each flow can be clicked straight through. This is a demo convenience only, not a product behavior.

## 2026-11-03 · Mockup round 2: glass bubble, glow, write-your-own, agent switching

Kirby's feedback on M0, applied to the mockup:

- **Bubble is macOS-style glass** (translucent gradient, heavy backdrop blur, a light inner edge) with Raycast/Linear density: smaller hairline chips, a 16px input, and a footer bar with the agent picker on the left and key hints on the right. Notifications, menus and the menu-bar panel use the same glass. In M1 this maps to `NSVisualEffectView` (SwiftUI materials) or a vibrancy window in Tauri.
- **Rainbow glow marks big moments only:** summon and paste. It is a ring around the pointer plus a one-shot edge on the bubble, about 1.5 s, never looping. We draw it in our own transparent overlay window. We do not replace or restyle the system cursor: macOS doesn't let an app do that outside its own windows, and it would fight users' pointer size and color settings in Accessibility. With Reduce Motion on, it becomes a still edge with no movement. It never flashes more than once.
- **Notifications stay off the cursor.** Waiting work shows in the menu-bar badge and macOS notifications. A badge on the cursor was rejected as too distracting.
- **Design rule: whenever the model offers a choice, the user can also type their own answer.** Applied to the "game idea or Inbox?" fallback, the reroute menu (type a project or a new name), approval notifications (Reply… next to Approve and Deny), and the Inbox "make it a project?" suggestion. Typing a name that doesn't exist creates the project.
- **Agents are per project, overridable per request.** Each project session has a default agent (Claude Code for now). The coordinator picks the project; the project picks the agent. The bubble footer shows the agent and lets you override it for one request, or you can type `/openclaw` in the request. The routing chip and log always show both, e.g. "→ shop · Claude Code". Changing a project's default agent belongs in settings (not mocked).

## 2026-11-03 · Mockup round 3: roomier bubble, four context-chip styles

- **More breathing room:** the bubble is 460px wide with a 16px corner radius and roughly 4px more padding throughout (chips, input, reply, footer).
- **Context chips get a tinted icon per kind** (app, file, selection, URL, terminal, secret, screenshot thumbnail) so items scan by shape and color, not only by text.
- **Four chip styles to compare, switchable in the mockup's left panel:** Pills (default), Inline (a single breadcrumb line, remove on hover), Tiles (attachment cards with a second line of detail), and Stack (overlapping icons with a count, click to expand). Not decided yet; Kirby to pick.
- **The mockup no longer auto-focuses text fields on touch screens.** On a phone the keyboard kept opening and scrolling the page. This only affects the demo, not the Mac app.

## 2026-11-03 · Mockup round 4: compact pills with overflow stack, pointer-shaped glow, engraved agent marks

- **Context chips: Pills, made compact** (20px tall, 14px icons, roughly the size of the old inline style). Kirby picked this over Inline, Tiles and Stack; the style switcher is gone.
- **Chips stay on one line.** Items that don't fit tuck into a stack of overlapping icons with a count ("+2") at the end; click it to show everything, "Show less" to collapse. Items tuck from the end, and the "secret redacted" chip never tucks, so what gets redacted is always visible.
- **The cursor glow is now an outline in the shape of the pointer**, rippling out from the tip in two echoes, instead of a circle. Still drawn in our own overlay; the system cursor is untouched. Reduce Motion shows a single still outline.
- **Agents get engraved marks:** each glyph is cut into a small metal-tinted tile (copper for Claude Code, red for OpenClaw, steel for Auto), with a highlight under each cut. The glyphs are our own generic shapes (a spark, three claw slashes, a split arrow), not the vendors' logos. In the real app, each adapter can supply its own icon, and we'd confirm brand-use rules before showing official logos.

## 2026-11-04 · Cursor glow zips around the pointer outline

Replaces the ripple. A short rainbow light travels around the pointer's outline (about 1.5 laps in 1.1 s), the full outline glows once, and then it's gone. It's drawn just under the real pointer in our own overlay, so only the rim outside the pointer's white edge lights up. The system cursor is untouched. Reduce Motion shows the full outline, still, for a moment. In M1 this needs the pointer's real shape and size (users can enlarge it in Accessibility settings), so the overlay must read the current cursor image rather than assume the default arrow.

## 2026-11-04 · Subtler rainbow edge on the bubble

The bubble's summon edge is now a 1px rainbow line at about 90% strength, with a soft 6px halo at about 35% (was 1.5px plus a wide 16px halo at full strength). Kirby wanted it smaller and quieter; the pointer glow stays the main moment.

## Pending

- **Agent override (M3):** when you switch agents for one request, does it start a second session in the same project folder, or hand the running session's summary to the other agent? The mockup assumes a separate session that shares the project summary.

- **Tech stack (SwiftUI vs Tauri):** to be proposed after M0 is reviewed. No system code until approved.

## 2026-11-04 · Stack: native Swift app plus a TypeScript daemon

Answers the SPEC's open questions on tech stack and Claude Code integration. Full reasoning in the [stack recommendation doc](https://claude.ai/artifact/QCowsVcKxmzbciXSdpAer6); Kirby approved each choice below.

- **Mac app in Swift 6** (SwiftUI on AppKit), not Tauri or Electron. The bubble is a non-activating `NSPanel` with native glass; capture uses the Accessibility API and ScreenCaptureKit directly.
- **Daemon in TypeScript on Bun**, compiled to one binary inside the app bundle and run as a LaunchAgent. The app talks to it over a local WebSocket. Two languages is accepted because the Claude Agent SDK and OpenClaw are TypeScript, and the daemon can be reused if a Windows UI ever happens.
- **Claude Code through the Claude Agent SDK**, not by parsing `claude -p` output. It signs in with the user's Claude subscription first; API keys come later.
- **Page context comes from the Accessibility tree**, which holds a web page's full text, including what's scrolled off screen. The screenshot is for visuals only. By default we send the text around the selection plus the page headings. The full page text is captured at summon and held locally in the daemon. Tapping the page-text chip switches that request to the full page, and a setting can make full page the default, globally or per site. The agent can also fetch the rest itself in the background through the context MCP server (M5), served from that held copy, so it matches what you were looking at and needs no new capture. Fetching the URL is a fallback for public pages.
- **No browser extension in v1.** Revisit only if Accessibility gaps show up in real use. Known gaps: canvas apps (Google Docs, Figma) and virtualized lists (Slack, Gmail, Notion).
- **Supports macOS 15 and up**, with native glass on macOS 26 and a close material fallback on 15.
- **Distribution outside the Mac App Store** (signed, notarized DMG with Sparkle updates), because the sandbox blocks the Accessibility features Superclick needs.

## 2026-11-10 · M1 built; the page-text spike became part of it

Kirby was away, so instead of running the spike first, its code became M1's capture code (`app/Sources/SuperclickCapture/PageReader.swift`) and the check ships twice: as a window in the app (menu bar → Page-text check…) and as the `pagetext` command. Kirby runs both on a Mac with the first build. If the check fails in a browser, the capture code changes, not the plan, unless Accessibility turns out not to expose the page at all.

- **One Swift package, no Xcode project.** `scripts/build-app.sh` builds it and wraps it in a signed `.app`. Easy to review and to build in CI; an Xcode project can come with notarization.
- **Swift 5 language mode for now.** The code was written in the cloud where Swift can't be compiled, so strict-concurrency issues stay warnings until it builds clean on a Mac. Then move to Swift 6 mode.
- **CI builds the app on a macOS runner** and runs the core tests, so compile errors are caught before Kirby's first build.
- **The bubble appears first, then fills in.** On the hotkey it shows at once with the app chip, then adds title, file and selection (one quick Accessibility read), then the page text, then the screenshot. The timings for each step are kept for the page-text check, against the 300 ms target.
- **Enter copies the request with its context** to the clipboard in M1, so the bubble is useful before agents arrive. The footer says so. From M2 Enter sends to the agent.
- **The daemon is optional in M1.** It holds each request with its context (in memory, 50 entries, an hour) for the context MCP server. It listens on 127.0.0.1 only, requires a token from a file only the user can read, and refuses any connection with an Origin header, so web pages can't talk to it.
- **Hotkey through Carbon `RegisterEventHotKey`**, which needs no permission and sees no other keystrokes. ⌥Space is the default with three alternatives in Settings, since Raycast and Alfred like ⌥Space too.
- **The cursor glow reads the real pointer image** (`NSCursor.currentSystem`) and the Accessibility pointer size, and is drawn in a click-through overlay. The system cursor is untouched.
- **Redaction rules:** private keys, Anthropic/OpenAI/GitHub/AWS/Slack/Stripe/Google keys, JWTs, bearer tokens, secrets in URL parameters, and `password=` / `api_key:` style assignments. Each is replaced with a visible `[redacted …]` and counted in the secrets chip.
- **Default blocklist:** password managers (1Password, Bitwarden, Dashlane, LastPass, Apple Passwords, Keychain Access, KeePassXC) and a starter list of sign-in, payment and bank sites. Editable in Settings.
- **Known gaps.** Private windows are only caught when the title says so (Firefox, some Chromium browsers); Safari private windows aren't detected yet. VS Code and other Electron editors may not expose the file path, only the title. Paste here and its glow came with M2.

## 2026-11-10 · Adversarial review of M1

Ten findings, all fixed before M2: nothing is sent before the blocklist has seen the page's URL (the bubble waits for the capture to finish), a browser page without a readable URL gets no screenshot, unsent screenshots are deleted on close, the hotkey works while a Superclick window is in front, permission status refreshes, thumbnails are decoded once, the glow timer race and out-of-order capture reports are fixed, the daemon validates headings and survives a bad message, the request store is capped by size as well as count, the token file is set back to 0600 at start, and redaction no longer re-matches its own placeholders, counts one secret once across fields, and catches short passwords.

## 2026-11-10 · M2: Claude Code through the Agent SDK

- **The daemon drives Claude Code with the Claude Agent SDK** (`query()` with `resume`), signed in with the user's Claude Code login. No API key, and the user's CLAUDE.md, settings and MCP servers apply as usual.
- **Routing is deterministic for now:** the terminal's folder, else the open file's folder, widened to the git root; else Inbox in the home folder. One session per folder, resumed across requests. The routing chip shows where it went and why. The model-based coordinator and rerouting come later (M3).
- **Approvals:** local reads (Read, Glob, Grep, LS, TodoWrite, NotebookRead) run freely. Everything else, including WebFetch and WebSearch, waits for Allow, Deny, or typed instructions, which go back to Claude as the denial message. Web tools ask because captured page text is untrusted and could tell the agent to send data to a URL. An unanswered approval is denied after 10 minutes.
- **The prompt is built in the app** (`PromptText`) so "copy with context" and "send" give Claude the same text; the daemon also keeps the structured bundle for the later context MCP server.
- **Paste here** puts the answer on the clipboard, sends ⌘V to the app underneath, then restores the previous clipboard unless something else changed it in the meantime. It needs Accessibility, which Superclick already has.
- **Closing the bubble doesn't stop the request.** The menu-bar icon gets a dot when an answer or approval is waiting, and "Show last answer" reopens it at the pointer. If the app disconnects, the running request finishes but its events are dropped; catching up after a reconnect is M4.

## 2026-11-10 · Adversarial review of M2

Twelve findings, all fixed in M3's commit. The biggest: sessions load only the user's own Claude Code settings (`settingSources: ["user"]`), so a cloned repo's hooks and allow rules can't run things without asking; its CLAUDE.md is still read, as text. Reads run freely only inside the session's folder, and the prompt marks captured context as untrusted. Approval cards show the full command or diff, every tool call is shown, a turn always ends, a stale resume retries fresh, the app catches up after a reconnect, approvals queue, every waiting bubble is reachable, and there's a Stop button. Paste here marks the clipboard as transient and always restores it.

## 2026-11-10 · M3: the coordinator

- **SQLite** in `~/Library/Application Support/Superclick/superclick.db` (owner-only): projects, rules, sessions with summaries, the routing log, events. Request text stays in memory.
- **Routing steps 1–6 as in SPEC**, cheapest first. The model step uses a small fast model (Haiku) with no tools and every input escaped as data, threshold 0.6; offline it backs off for a minute and routing falls through to Inbox.
- **Git repos become projects on their own**, except the home folder, `/`, Superclick's own folder, and repos the user removed.
- **Learned rules are narrow.** A reroute teaches a site rule for one repo, document or section, never a whole host, never mail, chat, calendars, localhost or IPs, and never an app rule (too broad to learn silently; add those in Projects). Choosing from the low-confidence offer teaches nothing, since it's an answer, not a correction.
- **Recent focus needs the same app**, plus the same window or follow-up wording, so a new question in another app isn't swallowed by the last project.
- **Paths compare through symlinks and case** (APFS is case-insensitive by default).

## 2026-11-10 · Adversarial review of M3

Eleven findings, all fixed in M5's commit: narrow learned rules (above), reroute failures land on the bubble, removing or moving a project stops its turns, Stop works while routing and while queued, home and removed repos are never adopted, Glob patterns that climb out of the folder ask first, URL globs run in linear time, summaries update one at a time, and the Projects window keeps what you're typing. Partly addressed: a page could still nudge the classifier's choice; its inputs are escaped, and a wrong guess only moves a request, which is one tap to undo.

## 2026-11-10 · M4: following long tasks

- **Notifications go to Notification Center** with Allow, Deny and a typed Reply, so approving never needs the bubble. Only for closed bubbles; an open bubble already shows it.
- **"While you were away" is built from an event log**: what ran (first line of each request and tool), files changed, how it ended. First lines only, kept a week; the routing log is kept four weeks.
- **The daemon is compiled with `bun build --compile`** with Claude Code embedded, put inside the app, and started at login as a LaunchAgent through SMAppService. Development can still use `bun run start`.

## 2026-11-10 · M5: context tools for the agent

- **`what_am_i_looking_at` always needs an approval**, even if the user's settings allow everything else; a capture is the one thing the agent can't take silently. It goes through the same blocklist and redaction as a summon, and the menu bar shows that it happened.
- **`recent_context` runs freely**: it only returns what the user already sent with a recent request.
- **A fresh MCP server instance per turn**, since the SDK's in-process servers hold per-query state.


## 2026-11-10 · Adversarial reviews of M4 and M5

Twenty-four findings between them, all fixed except where noted. The ones that changed a decision:

- **Approvals wait 12 hours, not 10 minutes**, since following a task from the desktop means coming back much later. When one ends without an answer (timeout, Stop, the turn ending), the app is told, so no bubble, badge or notification keeps offering Allow.
- **`recent_context` sees only its own project's captures** and defaults to the one sent with the turn, so one project's agent can't read a page or email you sent to another.
- **`what_am_i_looking_at` is declared `always_ask`** to Claude Code, so an allow rule in the user's own settings can't skip its approval card.
- **Reads of paths starting with `~` always ask**, since Claude Code expands them to the home folder.
- **Learned site rules skip segments every page shares** (`/wiki/`, `/item`, `/questions/`), so a move teaches one article or section, not the whole site.
- **The login daemon logs to `~/Library/Logs/Superclick/daemon.log`** (owner-only) instead of `/tmp`, gets the login shell's PATH, and exits cleanly when another daemon has the port so launchd doesn't restart it in a loop.
- Not done: a project folder on a stalled network share can still block the daemon briefly on its first path check (results are cached for a few seconds after that).
