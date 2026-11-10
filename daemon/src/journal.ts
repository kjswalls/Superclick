import type { Database } from "bun:sqlite";

// The session event log (SPEC data model: "Event: session id, type, payload").
// It powers the "while you were away" cards: what ran, what changed, what's
// waiting. It keeps the first line of each request and the start of each
// answer, never the captured context, and forgets everything after a week.

export type JournalType = "request" | "tool" | "changed" | "approval" | "done" | "error";

export interface CatchUpRequest {
  id: string;
  /** The first line of what was asked. */
  text: string;
  status: "running" | "waiting" | "done" | "failed";
  startedAt: number;
  endedAt?: number;
  /** Tool lines, oldest first ("Bash bin/rails test"). */
  ran: string[];
  /** Files written or edited. */
  changed: string[];
  /** The start of the answer, or the error. */
  answer?: string;
  /** Approvals still waiting, so the card can answer them. */
  waiting?: { approvalId: string; tool: string; summary: string; detail: string }[];
}

export interface CatchUpCard {
  projectId: string;
  project: string;
  summary: string;
  requests: CatchUpRequest[];
}

const KEEP_MS = 7 * 24 * 60 * 60 * 1000;
const WRITE_TOOLS = new Set(["Write", "Edit", "MultiEdit", "NotebookEdit"]);

/** The file a tool call changes, if it's one that writes. */
export function changedPath(tool: string, input: Record<string, unknown>): string | undefined {
  if (!WRITE_TOOLS.has(tool)) return undefined;
  const p = input.file_path ?? input.notebook_path;
  return typeof p === "string" ? p : undefined;
}

export class Journal {
  private writes = 0;

  constructor(private readonly db: Database, private readonly clock: () => number = Date.now) {
    this.prune();
  }

  add(projectId: string, requestId: string, type: JournalType, payload: Record<string, unknown>) {
    this.db.query("INSERT INTO events (project_id, request_id, type, payload, at) VALUES (?, ?, ?, ?, ?)")
      .run(projectId, requestId, type, JSON.stringify(payload), this.clock());
    if (++this.writes % 200 === 0) this.prune();
  }

  /** Drops events older than a week, and routing log entries older than a month. */
  prune() {
    const now = this.clock();
    this.db.query("DELETE FROM events WHERE at < ?").run(now - KEEP_MS);
    this.db.query("DELETE FROM routing_log WHERE at < ?").run(now - 4 * KEEP_MS);
  }

  /**
   * One card per project with activity since `since`: each request's status,
   * what it ran and changed, and how it ended. `live` marks requests still
   * running or waiting for an OK.
   */
  catchUp(since: number, names: (projectId: string) => { name: string; summary: string } | undefined,
          live: Map<string, "running" | "waiting">): CatchUpCard[] {
    const rows = this.db.query(
      "SELECT project_id, request_id, type, payload, at FROM events WHERE request_id IN " +
      "(SELECT DISTINCT request_id FROM events WHERE at >= ?) ORDER BY id",
    ).all(since) as { project_id: string; request_id: string; type: JournalType; payload: string; at: number }[];

    const requests = new Map<string, CatchUpRequest & { projectId: string }>();
    for (const r of rows) {
      let p: Record<string, unknown> = {};
      try {
        p = JSON.parse(r.payload);
      } catch {
        continue;
      }
      let q = requests.get(r.request_id);
      if (!q) {
        q = { id: r.request_id, projectId: r.project_id, text: "", status: "running", startedAt: r.at, ran: [], changed: [] };
        requests.set(r.request_id, q);
      }
      // A reroute starts the request over in another project.
      if (r.type === "request") {
        Object.assign(q, { projectId: r.project_id, text: String(p.text ?? ""), status: "running", startedAt: r.at,
          endedAt: undefined, ran: [], changed: [], answer: undefined });
      } else if (r.type === "tool") {
        q.ran = [...q.ran, String(p.summary ?? "")].slice(-12);
      } else if (r.type === "changed") {
        const path = String(p.path ?? "");
        if (path && !q.changed.includes(path)) q.changed.push(path);
      } else if (r.type === "done" || r.type === "error") {
        q.status = r.type === "done" ? "done" : "failed";
        q.endedAt = r.at;
        q.answer = String(p.text ?? "");
      }
    }

    const cards = new Map<string, CatchUpCard>();
    for (const q of requests.values()) {
      const state = live.get(q.id);
      if (state) q.status = state;
      else if (q.status === "running") q.status = "failed"; // the daemon stopped mid-turn
      const info = names(q.projectId);
      if (!info) continue;
      let card = cards.get(q.projectId);
      if (!card) {
        card = { projectId: q.projectId, project: info.name, summary: info.summary, requests: [] };
        cards.set(q.projectId, card);
      }
      const { projectId: _, ...rest } = q;
      card.requests.push(rest);
    }
    // Projects with something waiting first, then the most recent.
    const last = (c: CatchUpCard) => Math.max(...c.requests.map((r) => r.endedAt ?? r.startedAt));
    const waits = (c: CatchUpCard) => c.requests.some((r) => r.status === "waiting");
    return [...cards.values()]
      .map((c) => ({ ...c, requests: c.requests.reverse() }))
      .sort((a, b) => Number(waits(b)) - Number(waits(a)) || last(b) - last(a));
  }
}
