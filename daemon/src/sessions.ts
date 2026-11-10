import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import type { AgentAdapter, AgentSession } from "./agents/adapter.ts";
import type { ContextBundle } from "./protocol.ts";

export interface Route {
  /** The folder the session runs in. */
  cwd: string;
  /** Short name shown on the bubble's routing chip ("→ shop"). */
  project: string;
  /** Why this folder was picked, for the routing log. */
  reason: string;
}

/** The nearest folder at or above `start` that holds a .git, or undefined. */
export function gitRoot(start: string): string | undefined {
  let dir = start;
  for (let i = 0; i < 40; i++) {
    if (existsSync(join(dir, ".git"))) return dir;
    const up = dirname(dir);
    if (up === dir) return undefined;
    dir = up;
  }
  return undefined;
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/**
 * M2 picks one session per project folder from the captured context: the
 * terminal's folder or the file's folder, widened to its git repository.
 * Everything else goes to the Inbox session in the home folder. The full
 * coordinator (explicit target, URL rules, recent focus, model routing) is M3.
 */
export function routeFor(context: ContextBundle | undefined, inbox = homedir()): Route {
  const start = context?.cwd && isDir(context.cwd)
    ? context.cwd
    : context?.filePath
      ? dirname(context.filePath)
      : undefined;
  if (start && isDir(start)) {
    const root = gitRoot(start);
    if (root && root !== inbox) {
      return { cwd: root, project: basename(root), reason: `${context?.cwd ? "terminal folder" : "file"} is in the git repo ${root}` };
    }
    if (start !== inbox) {
      return { cwd: start, project: basename(start), reason: `${context?.cwd ? "terminal folder" : "file's folder"} ${start}` };
    }
  }
  return { cwd: inbox, project: "Inbox", reason: "no project folder in the context" };
}

export class SessionManager {
  private sessions = new Map<string, AgentSession>();
  constructor(private readonly adapter: AgentAdapter, private readonly inbox = homedir()) {}

  route(context: ContextBundle | undefined): { route: Route; session: AgentSession } {
    const route = routeFor(context, this.inbox);
    let session = this.sessions.get(route.cwd);
    if (!session) {
      session = this.adapter.startSession({ cwd: route.cwd });
      this.sessions.set(route.cwd, session);
    }
    return { route, session };
  }

  /** Every session, for approvals that arrive by id. */
  all(): AgentSession[] {
    return [...this.sessions.values()];
  }
}
