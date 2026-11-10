// Wire protocol between the Mac app and the daemon: JSON text frames over a
// local WebSocket at ws://127.0.0.1:47811/v1. Keep in step with
// app/Sources/Superclick/DaemonClient.swift and SuperclickCore/ContextBundle.swift.

export const PROTOCOL_VERSION = 1;

/** Mirrors SuperclickCore.ContextBundle (JSON-encoded with ISO 8601 dates). */
export interface ContextBundle {
  id: string;
  capturedAt: string;
  app: { name: string; bundleID?: string; pid: number };
  windowTitle?: string;
  filePath?: string;
  cwd?: string;
  url?: string;
  selection?: string;
  page?: {
    text: string;
    headings: { level: number; text: string }[];
    method: "textMarkers" | "treeWalk";
    wordCount: number;
  };
  screenshotPath?: string;
  redactions: Record<string, number>;
  blockedReason?: string;
  timings: Record<string, number>;
}

export type ClientMessage =
  | { type: "hello"; client: string; version: string }
  /** `prompt` is the request with its context rendered as Markdown by the app; `text` is what the user typed. */
  /** `project` is a project id picked in the bubble, or the project of the answer being replied to. */
  | { type: "request"; id: string; text: string; prompt?: string; fullPage: boolean; context: ContextBundle; project?: string }
  /** Moves a request to another project. `name` is typed in the bubble and makes a new project if none has it. */
  | { type: "request.reroute"; id: string; project?: string; name?: string }
  | { type: "projects.list" }
  /** The "while you were away" cards: activity since `since` (ms since 1970). */
  | { type: "catchup.get"; since: number }
  | { type: "projects.save"; project: { id?: string; name: string; paths?: string[]; description?: string } }
  | { type: "projects.remove"; id: string }
  | { type: "rules.save"; projectId: string; kind: "url" | "app"; pattern: string }
  | { type: "rules.remove"; id: number }
  /** `id` is the request the approval belongs to, so an expired one can be reported on its bubble. */
  | { type: "approval.answer"; approvalId: string; allow: boolean; message?: string; id?: string }
  | { type: "request.cancel"; id: string }
  | { type: "context.get"; captureId: string; part: "full" | "selection" | "outline" }
  | { type: "ping" };

export type ServerMessage =
  | { type: "welcome"; version: string; protocol: number }
  | { type: "request.accepted"; id: string; captureId: string; note: string; route?: RouteInfo }
  | { type: "reply.delta"; id: string; text: string }
  | { type: "reply.tool"; id: string; tool: string; summary: string }
  /** `detail` is the full input (whole command, file content), for the approval card. */
  | { type: "approval.needed"; id: string; approvalId: string; tool: string; summary: string; detail: string }
  | { type: "approval.expired"; id?: string; approvalId: string }
  /** Sent after hello: every run still going or recently finished, so a reconnected app can catch up. */
  | { type: "sync"; runs: RunSnapshot[] }
  | { type: "reply.done"; id: string; text: string }
  | { type: "reply.error"; id: string; message: string }
  | { type: "context"; captureId: string; part: string; text: string | null }
  | { type: "projects"; projects: ProjectInfo[] }
  | { type: "catchup"; since: number; cards: CatchUpCard[] }
  | { type: "pong" }
  | { type: "error"; error: string; detail?: string };

export interface RouteInfo {
  projectId: string;
  /** Short name for the routing chip ("→ shop"). */
  project: string;
  cwd: string;
  agent: string;
  reason: string;
  /** Which routing step decided: explicit, path, rule, recent, model or fallback. */
  step: string;
  confidence?: number;
  /** Low confidence: projects to offer with one tap. */
  ask: { id: string; name: string }[];
}

export interface RunSnapshot {
  id: string;
  /** The first line of what was asked, for a bubble the app no longer has (it restarted). */
  asked: string;
  route?: RouteInfo;
  text: string;
  tools: string[];
  approvals: { approvalId: string; tool: string; summary: string; detail: string }[];
  status: "running" | "done" | "failed";
  final?: string;
  error?: string;
  startedAt: number;
  endedAt?: number;
}

export interface ProjectInfo {
  id: string;
  name: string;
  paths: string[];
  description: string;
  agent: string;
  summary: string;
  updatedAt?: number;
  rules: { id: number; kind: "url" | "app"; pattern: string; source: string }[];
}

export type { CatchUpCard } from "./journal.ts";
import type { CatchUpCard } from "./journal.ts";

export class ProtocolError extends Error {}

const isObj = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);
const isStr = (v: unknown): v is string => typeof v === "string";
const optStr = (v: unknown) => v === undefined || v === null || isStr(v);

/** Checks the shape of a context bundle well enough that later code can trust it. */
export function parseContext(v: unknown): ContextBundle {
  if (!isObj(v)) throw new ProtocolError("context must be an object");
  if (!isStr(v.id) || !v.id) throw new ProtocolError("context.id is required");
  if (!isObj(v.app) || !isStr(v.app.name) || typeof v.app.pid !== "number")
    throw new ProtocolError("context.app needs a name and a pid");
  for (const k of ["windowTitle", "filePath", "cwd", "url", "selection", "screenshotPath", "blockedReason"]) {
    if (!optStr(v[k])) throw new ProtocolError(`context.${k} must be a string`);
  }
  if (v.page !== undefined && v.page !== null) {
    const p = v.page;
    if (!isObj(p) || !isStr(p.text) || !Array.isArray(p.headings))
      throw new ProtocolError("context.page needs text and headings");
    for (const h of p.headings) {
      if (!isObj(h) || !isStr(h.text) || typeof h.level !== "number" || !Number.isFinite(h.level))
        throw new ProtocolError("context.page.headings need a level and text");
      // Pages can say aria-level="12"; clamp rather than refuse the request.
      h.level = Math.min(9, Math.max(0, Math.round(h.level)));
    }
    if (p.wordCount !== undefined && typeof p.wordCount !== "number")
      throw new ProtocolError("context.page.wordCount must be a number");
  }
  return {
    ...(v as unknown as ContextBundle),
    redactions: isObj(v.redactions) ? (v.redactions as Record<string, number>) : {},
    timings: isObj(v.timings) ? (v.timings as Record<string, number>) : {},
  };
}

export function parseClientMessage(raw: string): ClientMessage {
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    throw new ProtocolError("not JSON");
  }
  if (!isObj(v) || !isStr(v.type)) throw new ProtocolError("message needs a type");
  switch (v.type) {
    case "hello":
      return { type: "hello", client: isStr(v.client) ? v.client : "?", version: isStr(v.version) ? v.version : "?" };
    case "ping":
      return { type: "ping" };
    case "request":
      if (!isStr(v.id) || !v.id) throw new ProtocolError("request.id is required");
      if (!isStr(v.text) || !v.text.trim()) throw new ProtocolError("request.text is required");
      if (v.prompt !== undefined && !isStr(v.prompt)) throw new ProtocolError("request.prompt must be a string");
      return {
        type: "request",
        id: v.id,
        text: v.text,
        prompt: isStr(v.prompt) ? v.prompt : undefined,
        fullPage: v.fullPage === true,
        context: parseContext(v.context),
        project: isStr(v.project) && v.project ? v.project : undefined,
      };
    case "approval.answer":
      if (!isStr(v.approvalId)) throw new ProtocolError("approval.answer needs an approvalId");
      if (typeof v.allow !== "boolean") throw new ProtocolError("approval.answer needs allow: true or false");
      if (!optStr(v.message)) throw new ProtocolError("approval.answer message must be a string");
      return { type: "approval.answer", approvalId: v.approvalId, allow: v.allow, message: isStr(v.message) ? v.message : undefined,
        id: isStr(v.id) ? v.id : undefined };
    case "request.cancel":
      if (!isStr(v.id)) throw new ProtocolError("request.cancel needs an id");
      return { type: "request.cancel", id: v.id };
    case "request.reroute":
      if (!isStr(v.id) || !v.id) throw new ProtocolError("request.reroute needs an id");
      if (!optStr(v.project) || !optStr(v.name)) throw new ProtocolError("request.reroute project and name must be strings");
      if (!(isStr(v.project) && v.project) && !(isStr(v.name) && v.name.trim()))
        throw new ProtocolError("request.reroute needs a project or a name");
      return { type: "request.reroute", id: v.id, project: isStr(v.project) && v.project ? v.project : undefined,
        name: isStr(v.name) && v.name.trim() ? v.name.trim() : undefined };
    case "projects.list":
      return { type: "projects.list" };
    case "catchup.get":
      if (typeof v.since !== "number" || !Number.isFinite(v.since)) throw new ProtocolError("catchup.get needs since (ms)");
      return { type: "catchup.get", since: v.since };
    case "projects.save": {
      const p = v.project;
      if (!isObj(p) || !isStr(p.name) || !p.name.trim()) throw new ProtocolError("projects.save needs a project with a name");
      if (!optStr(p.id) || !optStr(p.description)) throw new ProtocolError("project id and description must be strings");
      if (p.paths !== undefined && (!Array.isArray(p.paths) || !p.paths.every((x) => isStr(x) && x.startsWith("/"))))
        throw new ProtocolError("project paths must be absolute paths");
      return { type: "projects.save", project: { id: isStr(p.id) ? p.id : undefined, name: p.name,
        paths: p.paths as string[] | undefined, description: isStr(p.description) ? p.description : undefined } };
    }
    case "projects.remove":
      if (!isStr(v.id)) throw new ProtocolError("projects.remove needs an id");
      return { type: "projects.remove", id: v.id };
    case "rules.save":
      if (!isStr(v.projectId) || (v.kind !== "url" && v.kind !== "app") || !isStr(v.pattern))
        throw new ProtocolError("rules.save needs a projectId, a kind (url or app) and a pattern");
      return { type: "rules.save", projectId: v.projectId, kind: v.kind, pattern: v.pattern };
    case "rules.remove":
      if (typeof v.id !== "number" || !Number.isInteger(v.id)) throw new ProtocolError("rules.remove needs an id");
      return { type: "rules.remove", id: v.id };
    case "context.get": {
      const part = v.part ?? "full";
      if (!isStr(v.captureId)) throw new ProtocolError("context.get needs a captureId");
      if (part !== "full" && part !== "selection" && part !== "outline")
        throw new ProtocolError("part must be full, selection or outline");
      return { type: "context.get", captureId: v.captureId, part };
    }
    default:
      throw new ProtocolError(`unknown message type ${JSON.stringify(v.type)}`);
  }
}
