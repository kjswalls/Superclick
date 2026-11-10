import type { Database } from "bun:sqlite";
import type { AgentAdapter, AgentSession } from "./agents/adapter.ts";
import type { Summarizer } from "./agents/quick.ts";
import type { Project, ProjectRegistry } from "./projects.ts";

export { gitRoot } from "./projects.ts";

export interface SessionInfo {
  projectId: string;
  agent: string;
  summary: string;
  updatedAt: number;
}

/**
 * One long-lived agent session per project (SPEC: "each project is a folder
 * with its own long-lived agent session"). The agent's session id and the
 * running summary are saved, so a restarted daemon picks the conversation up again.
 */
export class SessionManager {
  private sessions = new Map<string, AgentSession>();
  /** Summary updates run one after another per project, so two finishing turns can't overwrite each other. */
  private summaryChain = new Map<string, Promise<void>>();

  constructor(
    private readonly adapter: AgentAdapter,
    private readonly registry: ProjectRegistry,
    private readonly db: Database,
    private readonly summarizer?: Summarizer,
  ) {}

  get agentName(): string {
    return this.adapter.name;
  }

  session(project: Project): AgentSession {
    let s = this.sessions.get(project.id);
    if (!s) {
      const row = this.db.query("SELECT sdk_session_id FROM sessions WHERE project_id = ?").get(project.id) as { sdk_session_id: string | null } | null;
      s = this.adapter.startSession({
        cwd: this.registry.folder(project),
        resumeId: row?.sdk_session_id ?? undefined,
        onSessionId: (id) => this.saveSessionId(project.id, id),
      });
      this.sessions.set(project.id, s);
    }
    return s;
  }

  /** Ends a project's session (it was removed, or its folder changed): its turns stop and its approvals are denied. */
  drop(projectId: string) {
    this.sessions.get(projectId)?.cancel();
    this.sessions.delete(projectId);
  }

  private saveSessionId(projectId: string, id: string) {
    if (!this.registry.get(projectId)) return;
    this.db.query(
      "INSERT INTO sessions (project_id, agent, sdk_session_id, updated_at) VALUES (?, ?, ?, ?) " +
      "ON CONFLICT (project_id) DO UPDATE SET sdk_session_id = excluded.sdk_session_id, updated_at = excluded.updated_at",
    ).run(projectId, this.adapter.name, id, Date.now());
  }

  summary(projectId: string): string {
    const row = this.db.query("SELECT summary FROM sessions WHERE project_id = ?").get(projectId) as { summary: string } | null;
    return row?.summary ?? "";
  }

  info(): SessionInfo[] {
    const rows = this.db.query("SELECT project_id, agent, summary, updated_at FROM sessions").all() as
      { project_id: string; agent: string; summary: string; updated_at: number }[];
    return rows.map((r) => ({ projectId: r.project_id, agent: r.agent, summary: r.summary, updatedAt: r.updated_at }));
  }

  /** Updates the running summary after a turn. Never blocks the reply; a failed model call keeps the last summary. */
  updateSummary(projectId: string, request: string, answer: string): Promise<void> {
    const next = (this.summaryChain.get(projectId) ?? Promise.resolve()).then(() => this.writeSummary(projectId, request, answer), () => {});
    this.summaryChain.set(projectId, next);
    return next;
  }

  private async writeSummary(projectId: string, request: string, answer: string): Promise<void> {
    if (!this.registry.get(projectId)) return;
    const previous = this.summary(projectId);
    const fallback = `Last asked: ${request.split("\n")[0]!.slice(0, 160)}`;
    const next = (await this.summarizer?.summarize(previous, request, answer).catch(() => undefined)) ?? (previous || fallback);
    this.db.query(
      "INSERT INTO sessions (project_id, agent, summary, updated_at) VALUES (?, ?, ?, ?) " +
      "ON CONFLICT (project_id) DO UPDATE SET summary = excluded.summary, updated_at = excluded.updated_at",
    ).run(projectId, this.adapter.name, next, Date.now());
  }

  /** Every live session, for approvals that arrive by id. */
  all(): AgentSession[] {
    return [...this.sessions.values()];
  }
}
