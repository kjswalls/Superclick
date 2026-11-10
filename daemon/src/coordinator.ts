import type { Database } from "bun:sqlite";
import { dirname } from "node:path";
import type { Classifier } from "./agents/quick.ts";
import { INBOX_ID, canLearnAppRule, gitRoot, isDir, ruleForURL, type Project, type ProjectRegistry, type Rule } from "./projects.ts";
import type { ContextBundle } from "./protocol.ts";

// The coordinator's routing (SPEC "Coordinator and inbox"). First match wins,
// and each step is cheaper than the next:
//   1 explicit target  2 path match  3 app or URL rule  4 recent focus
//   5 model classification  6 fallback to Inbox, asking with one tap.
// It only routes; it never does the task itself.

export type RouteStep = "explicit" | "path" | "rule" | "recent" | "model" | "fallback";

export interface RouteDecision {
  project: Project;
  step: RouteStep;
  /** Shown on the routing chip's tooltip and kept in the routing log. */
  reason: string;
  confidence?: number;
  /** Low confidence: other projects the bubble offers with one tap ("shop or Inbox?"). */
  ask: Project[];
  /** The `@name` the user typed, if any, so it can be taken out of the prompt. */
  mention?: string;
}

export interface RouteRequest {
  id: string;
  text: string;
  context?: ContextBundle;
  /** A project id picked in the bubble, or the project of the answer being replied to. */
  project?: string;
}

const FOLLOW_UP = /^(and|also|now|then|ok(ay)?|thanks|what about|how about|try|do it|go ahead|yes|yep|no|nope|it|that|same|again|undo|continue|more|but|why)\b/i;

/** "@shop fix the test" → "shop". Only a mention at a word start counts, not an email address. */
export function findMention(text: string): string | undefined {
  const m = /(?:^|\s)@([A-Za-z0-9][\w.-]{0,59})/.exec(text);
  return m?.[1];
}

/** Takes the first `@name` out of a prompt, leaving the rest as it was. */
export function stripMention(text: string, name: string): string {
  const re = new RegExp(`(^|\\s)@${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b\\s?`, "i");
  return text.replace(re, "$1");
}

/** A short description of the context for the classifier. Never the page text. */
export function contextSummary(c: ContextBundle | undefined): string {
  if (!c) return "";
  const parts = [`app: ${c.app.name}`];
  if (c.windowTitle) parts.push(`window: ${c.windowTitle.slice(0, 120)}`);
  if (c.url) parts.push(`url: ${c.url.slice(0, 200)}`);
  if (c.filePath) parts.push(`file: ${c.filePath}`);
  if (c.cwd) parts.push(`folder: ${c.cwd}`);
  if (c.selection) parts.push(`selection starts: ${c.selection.slice(0, 300)}`);
  return parts.join("\n");
}

interface Focus {
  projectId: string;
  at: number;
  bundleID?: string;
  place?: string;
}

export class Coordinator {
  private focus?: Focus;

  constructor(
    readonly registry: ProjectRegistry,
    private readonly db: Database,
    private readonly classifier?: Classifier,
    private readonly opts: { recentMs?: number; threshold?: number; clock?: () => number; summaries?: (projectId: string) => string } = {},
  ) {}

  private get now() {
    return (this.opts.clock ?? Date.now)();
  }

  async route(req: RouteRequest): Promise<RouteDecision> {
    const c = req.context;
    const reg = this.registry;
    const decide = (project: Project, step: RouteStep, reason: string, extra: Partial<RouteDecision> = {}): RouteDecision =>
      ({ project, step, reason, ask: [], ...extra });

    // 1. Explicit target: picked in the bubble, a reply in the same bubble, or "@shop" in the text.
    if (req.project) {
      const p = reg.get(req.project);
      if (p) return decide(p, "explicit", "picked in the bubble");
    }
    const mention = findMention(req.text);
    if (mention) {
      const p = reg.byName(mention);
      if (p) return decide(p, "explicit", `you wrote @${p.name}`, { mention });
    }

    // 2. Path match: the terminal's folder or the file sits in a project's folder.
    // An unregistered git repository becomes a project of its own.
    const start = c?.cwd && isDir(c.cwd) ? c.cwd : c?.filePath ? dirname(c.filePath) : undefined;
    if (start && !c?.blockedReason) {
      const where = c?.cwd ? "terminal folder" : "file";
      const p = reg.matchPath(start);
      if (p) return decide(p, "path", `${where} is in ${p.paths.find((f) => start.startsWith(f)) ?? p.name}`);
      const root = isDir(start) ? gitRoot(start) : undefined;
      if (root) {
        const made = reg.adoptRepo(root);
        return decide(made, "path", `${where} is in the git repo ${root} (new project)`);
      }
    }

    // 3. App or URL rule.
    const hit = c && !c.blockedReason ? reg.matchRule(c.url, c.app.bundleID) : undefined;
    if (hit) return decide(hit.project, "rule", `${hit.rule.kind === "url" ? "site" : "app"} rule ${hit.rule.pattern}`);

    // 4. Recent focus: a follow-up to the last request, from the same place or worded like one.
    const f = this.focus;
    if (f && this.now - f.at < (this.opts.recentMs ?? 5 * 60 * 1000)) {
      const p = reg.get(f.projectId);
      const samePlace = !!c && c.app.bundleID === f.bundleID && !!placeOf(c) && placeOf(c) === f.place;
      const worded = FOLLOW_UP.test(req.text.trim()) && !c?.selection;
      if (p && (samePlace || worded)) return decide(p, "recent", samePlace ? "same window as your last request" : "follow-up to your last request");
    }

    // 5. Model classification over the projects' descriptions and summaries.
    const projects = reg.list().filter((p) => p.id !== INBOX_ID);
    if (projects.length && this.classifier) {
      const result = await this.classifier.classify({
        text: req.text,
        context: c?.blockedReason ? `app: ${c.app.name}` : contextSummary(c),
        projects: projects.map((p) => ({ name: p.name, description: p.description, summary: this.opts.summaries?.(p.id) ?? "" })),
      });
      if (result) {
        const guess = result.project.toLowerCase() === "inbox" ? reg.inbox : reg.byName(result.project);
        const threshold = this.opts.threshold ?? 0.6;
        if (guess && result.confidence >= threshold) {
          return decide(guess, "model", result.why || `looks like ${guess.name}`, { confidence: result.confidence });
        }
        // 6. Low confidence: Inbox, and offer the best guess with one tap.
        const ask = guess && guess.id !== INBOX_ID ? [guess] : this.recentProjects(2);
        return decide(reg.inbox, "fallback", guess && guess.id !== INBOX_ID ? `not sure; maybe ${guess.name}` : "no project fits", { confidence: result.confidence, ask });
      }
    }

    // 6. Fallback.
    return decide(reg.inbox, "fallback", projects.length ? "couldn't tell which project" : "no projects yet", { ask: this.recentProjects(2) });
  }

  /** Remembers where a request went, for recent focus and the routing log. */
  noteRouted(req: RouteRequest, d: RouteDecision) {
    const c = req.context;
    this.focus = { projectId: d.project.id, at: this.now, bundleID: c?.app.bundleID, place: c ? placeOf(c) : undefined };
    this.db.query(
      "INSERT OR REPLACE INTO routing_log (request_id, project_id, step, reason, confidence, app, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).run(req.id, d.project.id, d.step, d.reason, d.confidence ?? null, c?.app.bundleID ?? c?.app.name ?? null, this.now);
  }

  /**
   * A reroute moves the request and teaches a rule, so the same site or app
   * goes there next time (SPEC: "Reroutes become new rules"). Moving to Inbox
   * teaches nothing.
   */
  learnFromReroute(context: ContextBundle | undefined, to: Project): Rule | undefined {
    if (!context || context.blockedReason || to.id === INBOX_ID) return undefined;
    if (context.cwd || context.filePath) return undefined; // folders route by path; add the folder in Settings instead
    const pattern = context.url ? ruleForURL(context.url) : undefined;
    if (pattern) return this.registry.addRule(to.id, "url", pattern, "reroute");
    if (!context.url && canLearnAppRule(context.app.bundleID)) return this.registry.addRule(to.id, "app", context.app.bundleID!, "reroute");
    return undefined;
  }

  /** Projects used most recently, newest first. */
  recentProjects(n: number): Project[] {
    const rows = this.db.query(
      "SELECT project_id, MAX(at) AS last FROM routing_log WHERE project_id != 'inbox' GROUP BY project_id ORDER BY last DESC LIMIT ?",
    ).all(n) as { project_id: string }[];
    return rows.map((r) => this.registry.get(r.project_id)).filter((p): p is Project => !!p);
  }
}

/** The page or document the request came from, for "same window as last time". */
function placeOf(c: ContextBundle): string | undefined {
  return c.url ?? c.filePath ?? c.windowTitle ?? undefined;
}
