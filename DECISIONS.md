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

## Pending

- **Agent override (M3):** when you switch agents for one request, does it start a second session in the same project folder, or hand the running session's summary to the other agent? The mockup assumes a separate session that shares the project summary.

- **Tech stack (SwiftUI vs Tauri):** to be proposed after M0 is reviewed. No system code until approved.
