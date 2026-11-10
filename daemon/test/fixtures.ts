import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentAdapter } from "../src/agents/adapter.ts";
import type { Classifier, Summarizer } from "../src/agents/quick.ts";
import { Coordinator } from "../src/coordinator.ts";
import { openDatabase } from "../src/db.ts";
import { ProjectRegistry } from "../src/projects.ts";
import { SessionManager } from "../src/sessions.ts";

// A context bundle shaped like the one the Mac app sends.
export const bundle = (over: Record<string, unknown> = {}) => ({
  id: "cap-1",
  capturedAt: "2026-11-10T18:00:00Z",
  app: { name: "Safari", bundleID: "com.apple.Safari", pid: 42 },
  url: "https://example.com/article",
  selection: "actors isolate state",
  page: { text: "Intro. actors isolate state. End.", headings: [{ level: 1, text: "Intro" }], method: "textMarkers", wordCount: 5 },
  redactions: { "GitHub token": 1 },
  timings: { visible: 40 },
  ...over,
});

/** A fresh in-memory store, registry, sessions and coordinator, with Superclick's folder in a temp dir. */
export function world(adapter: AgentAdapter, opts: { classifier?: Classifier; summarizer?: Summarizer; clock?: () => number } = {}) {
  const home = mkdtempSync(join(tmpdir(), "sc-home-"));
  const db = openDatabase(":memory:");
  const registry = new ProjectRegistry(db, home);
  const sessions = new SessionManager(adapter, registry, db, opts.summarizer);
  const coordinator = new Coordinator(registry, db, opts.classifier, { clock: opts.clock, summaries: (id) => sessions.summary(id) });
  return { home, db, registry, sessions, coordinator };
}
