# Cursor Companion — Product & Build Brief

> **Code name: Superclick.** The brief below uses the working name "Cursor Companion". The product name is still open (see DECISIONS.md); code and docs use Superclick.

Nov 3, 2026 · Kirby Walls

## Vision

Cursor Companion (working name) is a presence layer that keeps your existing AI agents one keystroke away anywhere on your computer and one tap away on your phone. It sees what you're looking at, sends each request to the right agent session, and puts results back where you're working.

It does not bring its own AI. It wraps the agents you already use: Claude Code first, then OpenClaw, then others through adapters. The product is the glue: summon, see, route, follow.

**One-line pitch:** your AI agents, attached to your cursor.

## Problem

Working with agents today means constant copy-paste in both directions.

- **Context in:** copying errors, file paths, URLs and screenshots into a chat, then re-explaining what you were doing.
- **Results out:** copying the agent's answer back into the editor, terminal, browser or message you came from.
- **Device gaps:** something you find on your phone (a link, a photo, an idea) has to be carried back to the computer by hand.
- **Thread juggling:** you decide which chat or session each request belongs in, and lose track of what's running.

Screen-aware assistants (Highlight, Littlebird, Caret) bring their own AI rather than driving your agents. Agent tools (Claude Code, OpenClaw) are powerful but live in a terminal or chat window. Nothing connects the two.

## Core pillars

The product does four things. All four ship in some form in v1; the phone side of Follow comes later.

| Pillar | What it does | v1 behavior |
|---|---|---|
| Summon | Opens the agent instantly, wherever you are | Global hotkey opens a floating bubble at the cursor, over any app |
| See | Captures what you're looking at, so you never paste or re-explain | On summon: active app, window title, selected text, window screenshot, browser URL or editor file path |
| Route | Sends each request to the right agent session | Coordinator inbox classifies the request and picks or creates a project session |
| Follow | Keeps work going and reachable across devices | Sessions run in a local daemon; results return to the bubble with "paste here"; a "while you were away" card. Phone comes in v2 |

## Key user flows

### 1. Point and ask (v1)

1. You hit an error in your editor and select the stack trace.
2. You press the hotkey (default ⌥Space). A bubble appears at the cursor with a context chip: "VS Code · app/models/order.rb · 14 lines selected · screenshot".
3. You type or say "why is this failing?" and press Enter.
4. The coordinator sees the file path is inside `~/code/shop`, so it routes the request to the shop project session and shows "→ shop" on the bubble.
5. The answer streams into the bubble. Buttons: Paste here, Copy, Open session, Reply.

### 2. Ask without a project (v1)

1. You're reading a blog post and select a paragraph.
2. Summon: "save this for the game idea, and summarize it."
3. The coordinator matches "game idea" to an existing project session and routes it there. If nothing matches, it goes to the general Inbox session.
4. The bubble confirms where it went. You can tap the chip to reroute it.

### 3. Long task, come back later (v1)

1. You ask the shop session to fix a failing test and walk away.
2. The agent needs approval to run a command. A desktop notification appears; you can approve from the notification.
3. When you return, the menu-bar icon shows a badge. Clicking it opens a "while you were away" card per session: what ran, what changed, what's waiting on you.

### 4. Phone handoff (v2)

1. Away from your desk, you get a push: "shop needs approval to run db:migrate." You approve from the lock screen.
2. You find a useful link and use Share → Companion. The coordinator routes it into the right session with its context intact.
3. Replies on the phone are short summaries with action buttons. The full diff waits on the desktop.

## Coordinator and inbox

The coordinator is the core of the product: one front door for every request, which decides which session handles it so you never pick a thread. It works like Claude Code projects: each project is a folder with its own long-lived agent session, plus one general Inbox session for everything else.

**Routing order** (first match wins; each step is cheap before the next):

1. **Explicit target.** "@shop" or a project picked on the bubble.
2. **Path match.** The captured file path or terminal cwd sits inside a registered project folder.
3. **App or URL rule.** User-defined rules, such as `github.com/me/shop/*` → shop.
4. **Recent focus.** The session you used in the last few minutes, if the new request looks like a follow-up.
5. **Model classification.** A small, fast model call gets the request, the context summary and each project's one-line description, and returns a project or "inbox" with a confidence score.
6. **Fallback.** Low confidence goes to Inbox, and the bubble asks "shop or Inbox?" with one tap.

**Design rules**

- Always show where a request went (a "→ shop" chip) and allow one-tap reroute. Reroutes become new rules.
- The coordinator only routes and summarizes. It never does the task itself, so it stays fast and cheap.
- The Inbox can spin off a new project: "this keeps coming up, make it a project?"
- Every session keeps a running summary the coordinator can read, which powers routing and the "while you were away" cards.

## Architecture

A local daemon is the center. It owns the coordinator and every agent session, so the bubble, notifications and later the phone are all windows into it.

The menu-bar app sends each request with its captured context to the coordinator, which picks a session. Sessions reach agents only through adapters.

### Components

| Component | Responsibility | Notes |
|---|---|---|
| Menu-bar app | Hotkey, bubble UI, context capture, notifications | Needs macOS Accessibility and Screen Recording permissions |
| Local daemon | Long-lived process hosting the coordinator, sessions and a local WebSocket API | Launches at login; keeps running when the UI closes |
| Coordinator | Routing, session summaries, catch-up cards | See Coordinator and inbox |
| Agent adapters | One interface over each agent | Claude Code first, via the CLI or the Agent SDK |
| Context MCP server | Lets agents request fresh context themselves | Reuses the app's capture code |
| Store | SQLite: projects, sessions, messages, routing log, rules | Local only |

### Data model (v1)

- **Project:** id, name, folder paths, one-line description, URL and app rules
- **Session:** id, project id, agent type, status, running summary
- **Request:** id, text, context bundle, routed project, routing reason, timestamps
- **ContextBundle:** app, window title, selection, screenshot path, URL or file path, cwd
- **Event:** session id, type (message, tool call, approval needed, done), payload

## MVP scope and milestones

v1 is Mac-only, Claude Code-first, and includes the coordinator. Each milestone ends with something usable every day.

| Milestone | Delivers | Done when |
|---|---|---|
| M0: Clickable mockup | Bubble UI, context chip, routing chip, "while you were away" card, all with fake data | You can click through flows 1–3 |
| M1: Summon + See | Menu-bar app, global hotkey, bubble at cursor, context capture, permissions onboarding | Hotkey shows correct context in under 300 ms |
| M2: Daemon + one agent | Local daemon, Claude Code adapter, one session, streamed replies, Paste here | A real question about real code gets answered from the bubble |
| M3: Coordinator | Project registry, routing steps 1–6, Inbox, reroute chip, session summaries | Requests land in the right project without picking one manually |
| M4: Follow (desktop) | Notifications, approvals, menu-bar badge, "while you were away" cards | A long task can be left and resumed without reading the full log |
| M5: Context MCP server | `what_am_i_looking_at` and `recent_context` tools agents can call | The agent can ask for a fresh screenshot itself |
| v2 | OpenClaw adapter, phone app or Remote Control bridge, share sheet, presence-aware notifications | — |

**Out of scope for v1:** Windows, always-on screen recording, the agent clicking or typing in other apps, team or multi-user features.

## Privacy and safety

Capture happens only when you summon. There is no background recording in v1.

- **Visible capture.** The context chip shows exactly what was grabbed before sending. Each item can be removed with one tap.
- **Blocklist.** Apps that are never captured (password managers, banking, private browsing). Ships with sensible defaults.
- **Local first.** The daemon, session logs and summaries live on your machine. Only the request and its context go to the model provider.
- **Approval tiers.** Read-only actions run freely. Edits and commands follow the agent's own permission prompts. Anything marked dangerous (deploys, deletes, payments) is desktop-only and can never be approved from a notification.
- **Secrets.** Redact obvious secrets (API keys, tokens) from captured text before sending.

## Open questions

- **Tech stack:** native Swift/SwiftUI (best for Accessibility APIs and feel) or Tauri (reuses web skills, easier Windows later)?
- **Claude Code integration:** run the CLI headless per session (`claude -p` / stream-json), or use the Agent SDK directly?
- Should the coordinator use the same agent backend, or a separate cheap model call?
- How does a project get registered: manually, by detecting git repos, or by the coordinator suggesting it?
- **Phone in v2:** build our own app, or ride on Claude Code Remote Control and the OpenClaw gateway?
- Name and pricing for a solo-dev product: one-time purchase, subscription, or bring-your-own-key free tier?

## Instructions for the Claude Code build agent

1. Start with M0, the clickable mockup. Build the bubble, context chip, routing chip, reply view and "while you were away" card with fake data. Stop and show it before writing any system code.
2. Propose the stack before M1. Compare SwiftUI and Tauri against the open questions above and recommend one with reasons. Wait for approval.
3. Build one milestone at a time in the order of the milestone table. Each must meet its "Done when" before moving on.
4. Keep agents behind an adapter interface: `start_session`, `send(message, context)`, `stream_events`, `approve(request_id)`, `summary()`. Claude Code is the first implementation; OpenClaw must fit later without changes to the coordinator.
5. The coordinator is its own module with the routing steps in order and a unit test per step. Log every routing decision with its reason.
6. Privacy rules are requirements, not polish. Visible capture, the blocklist and secret redaction ship in M1.
7. Keep a DECISIONS.md recording each choice made and why, and a README with setup steps, including macOS permissions (Accessibility, Screen Recording).
8. Ask instead of guessing whenever the spec is silent on something that's hard to reverse.
