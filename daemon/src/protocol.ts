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
  | { type: "request"; id: string; text: string; prompt?: string; fullPage: boolean; context: ContextBundle }
  | { type: "approval.answer"; approvalId: string; allow: boolean; message?: string }
  | { type: "request.cancel"; id: string }
  | { type: "context.get"; captureId: string; part: "full" | "selection" | "outline" }
  | { type: "ping" };

export type ServerMessage =
  | { type: "welcome"; version: string; protocol: number }
  | { type: "request.accepted"; id: string; captureId: string; note: string; route?: RouteInfo }
  | { type: "reply.delta"; id: string; text: string }
  | { type: "reply.tool"; id: string; tool: string; summary: string }
  | { type: "approval.needed"; id: string; approvalId: string; tool: string; summary: string }
  | { type: "reply.done"; id: string; text: string }
  | { type: "reply.error"; id: string; message: string }
  | { type: "context"; captureId: string; part: string; text: string | null }
  | { type: "pong" }
  | { type: "error"; error: string; detail?: string };

export interface RouteInfo {
  project: string;
  cwd: string;
  agent: string;
  reason: string;
}

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
      if (!isObj(h) || !isStr(h.text) || typeof h.level !== "number" ||
          !Number.isInteger(h.level) || h.level < 0 || h.level > 9)
        throw new ProtocolError("context.page.headings need a level from 0 to 9 and text");
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
      };
    case "approval.answer":
      if (!isStr(v.approvalId)) throw new ProtocolError("approval.answer needs an approvalId");
      if (typeof v.allow !== "boolean") throw new ProtocolError("approval.answer needs allow: true or false");
      if (!optStr(v.message)) throw new ProtocolError("approval.answer message must be a string");
      return { type: "approval.answer", approvalId: v.approvalId, allow: v.allow, message: isStr(v.message) ? v.message : undefined };
    case "request.cancel":
      if (!isStr(v.id)) throw new ProtocolError("request.cancel needs an id");
      return { type: "request.cancel", id: v.id };
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
