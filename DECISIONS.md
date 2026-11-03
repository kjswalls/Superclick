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

## Pending

- **Tech stack (SwiftUI vs Tauri):** to be proposed after M0 is reviewed. No system code until approved.
