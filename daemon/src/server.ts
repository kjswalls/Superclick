import type { Server, ServerWebSocket } from "bun";
import { tokenMatches } from "./auth.ts";
import { type Coordinator, type RouteDecision, stripMention } from "./coordinator.ts";
import type { Project } from "./projects.ts";
import {
  PROTOCOL_VERSION,
  ProtocolError,
  parseClientMessage,
  type AgentStatus,
  type ClientMessage,
  type ContextBundle,
  type ProjectInfo,
  type RouteInfo,
  type RunSnapshot,
  type ServerMessage,
} from "./protocol.ts";
import type { ContextService, FreshCapture } from "./contextMcp.ts";
import type { Journal } from "./journal.ts";
import { INSTALL_COMMAND, INSTALL_URL, findClaude } from "./agents/findClaude.ts";
import type { SessionManager } from "./sessions.ts";
import { RequestStore } from "./store.ts";

export const DEFAULT_PORT = 47811;
export const VERSION = "0.5.0";

export interface DaemonOptions {
  token: string;
  port?: number;
  store?: RequestStore;
  /** Agent sessions and the coordinator (M2, M3). Without them the daemon only holds requests, as in M1. */
  sessions?: SessionManager;
  coordinator?: Coordinator;
  /** The event log behind the catch-up cards (M4). */
  journal?: Journal;
  /** The context MCP server's link to the app (M5). */
  context?: ContextService;
  /** How long the app gets to answer a capture request. */
  captureTimeoutMs?: number;
  /** Which agents are installed (Claude Code by default; tests pass their own). */
  agentStatus?: (fresh: boolean) => AgentStatus[];
  log?: (line: string) => void;
}

/** Claude Code as found on this Mac. */
export function claudeCodeStatus(fresh: boolean): AgentStatus[] {
  const s = findClaude({ fresh });
  return [{
    name: "Claude Code",
    installed: s.source !== "missing",
    ...(s.path ? { path: s.path } : {}),
    ...(s.version ? { version: s.version } : {}),
    ...(s.source === "missing" ? { installCommand: INSTALL_COMMAND, installURL: INSTALL_URL } : {}),
  }];
}

interface Conn {
  client?: string;
}

/** One request's run in a project session. A reroute starts a new generation; older ones go quiet. */
interface Run {
  id: string;
  gen: number;
  abort: AbortController;
  projectId: string;
  /** What a reconnecting app needs to catch up. */
  snap: RunSnapshot;
}

/** Finished runs are kept this long for catch-up, at most KEEP_FINISHED of them. */
const FINISHED_MS = 60 * 60 * 1000;
const KEEP_FINISHED = 30;

/**
 * The daemon's local WebSocket API. It listens on 127.0.0.1 only, and accepts
 * a connection only when it presents the token from daemon.token and carries
 * no Origin header, so web pages in a browser can't reach it.
 */
function requestIdOf(raw: string | Buffer): string | undefined {
  try {
    const v = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
    return v && typeof v === "object" && v.type === "request" && typeof v.id === "string" ? v.id : undefined;
  } catch {
    return undefined;
  }
}

export function startDaemon(opts: DaemonOptions): { server: Server<Conn>; store: RequestStore; stop: () => void } {
  const store = opts.store ?? new RequestStore();
  const log = opts.log ?? ((l: string) => console.log(`[superclick] ${l}`));
  const clients = new Set<ServerWebSocket<Conn>>();

  const send = (ws: ServerWebSocket<Conn>, m: ServerMessage) => {
    if (ws.readyState === 1) ws.send(JSON.stringify(m));
  };
  /** Request events go to every connected app window, so a reconnect or a second window still hears them. */
  const broadcast = (m: ServerMessage) => {
    for (const ws of clients) send(ws, m);
  };
  const agentStatus = opts.agentStatus ?? claudeCodeStatus;
  const runs = new Map<string, Run>();
  /** Requests still being routed, so Stop works before their run starts. */
  const starting = new Map<string, AbortController>();
  const finished = new Map<string, RunSnapshot>();
  const captures = new Map<string, { resolve: (r: FreshCapture) => void; from: ServerWebSocket<Conn> }>();

  if (opts.context) {
    opts.context.capture = ({ screenshot, fullPage, projectId, signal }) => new Promise<FreshCapture>((resolve) => {
      // The Mac app that said hello most recently does the capture.
      const app = [...clients].reverse().find((ws) => ws.data.client?.startsWith("superclick-mac"));
      if (!app) return resolve({ markdown: "", refused: "The Superclick app isn't running." });
      if (signal?.aborted) return resolve({ markdown: "", refused: "Cancelled." });
      const requestId = crypto.randomUUID();
      const settle = (r: FreshCapture) => {
        clearTimeout(timer);
        captures.delete(requestId);
        signal?.removeEventListener("abort", onAbort);
        resolve(r);
      };
      const timer = setTimeout(() => settle({ markdown: "", refused: "The Superclick app didn't answer in time." }), opts.captureTimeoutMs ?? 15_000);
      // Stop (or the turn ending) calls the capture off, in the app too.
      const onAbort = () => {
        send(app, { type: "capture.cancel", requestId });
        settle({ markdown: "", refused: "Cancelled." });
      };
      signal?.addEventListener("abort", onAbort, { once: true });
      captures.set(requestId, { from: app, resolve: settle });
      const project = projectId ? opts.coordinator?.registry.get(projectId)?.name : undefined;
      log(`capture requested by an agent (screenshot: ${screenshot})`);
      send(app, { type: "capture.request", requestId, screenshot, fullPage, ...(project ? { project } : {}) });
    });
  }
  let generation = 0;

  const snapshots = (): RunSnapshot[] => {
    const cutoff = Date.now() - FINISHED_MS;
    for (const [id, s] of finished) if ((s.endedAt ?? 0) < cutoff) finished.delete(id);
    return [...[...runs.values()].map((r) => r.snap), ...finished.values()];
  };

  const projectInfo = (): ProjectInfo[] => {
    const c = opts.coordinator;
    if (!c) return [];
    const info = new Map(opts.sessions?.info().map((s) => [s.projectId, s]) ?? []);
    return c.registry.list().map((p) => ({
      ...p,
      summary: info.get(p.id)?.summary ?? "",
      updatedAt: info.get(p.id)?.updatedAt,
      rules: c.registry.rules(p.id).map(({ id, kind, pattern, source }) => ({ id, kind, pattern, source })),
    }));
  };
  const broadcastProjects = () => broadcast({ type: "projects", projects: projectInfo() });

  const routeInfo = (d: RouteDecision, cwd: string): RouteInfo => ({
    projectId: d.project.id,
    project: d.project.name,
    cwd,
    agent: opts.sessions?.agentName ?? "Claude Code",
    reason: d.reason,
    step: d.step,
    confidence: d.confidence,
    ask: d.ask.map((p) => ({ id: p.id, name: p.name })),
  });

  async function run(id: string, prompt: string, text: string, context: ContextBundle, decision: RouteDecision) {
    const sessions = opts.sessions!;
    const project: Project = decision.project;
    const session = sessions.session(project);
    const gen = ++generation;
    runs.get(id)?.abort.abort();
    finished.delete(id);
    const abort = new AbortController();
    const firstLine = text.split("\n")[0]!.slice(0, 200);
    const snap: RunSnapshot = { id, asked: firstLine, text: "", tools: [], approvals: [], status: "running", startedAt: Date.now() };
    const journal = (type: Parameters<Journal["add"]>[2], payload: Record<string, unknown>) => {
      if (!live()) return;
      try {
        opts.journal?.add(project.id, id, type, payload);
      } catch (e) {
        log(`journal: ${e instanceof Error ? e.message : String(e)}`);
      }
    };
    runs.set(id, { id, gen, abort, projectId: project.id, snap });
    // The context tools let a project's agent read only its own project's captures.
    const stored = store.get(context.id);
    if (stored) stored.projectId = project.id;
    const live = () => runs.get(id)?.gen === gen;
    const emit = (m: ServerMessage) => {
      if (live()) broadcast(m);
    };
    const finish = (status: "done" | "failed", text: string) => {
      if (!live()) return;
      snap.status = status;
      snap.approvals = [];
      snap.endedAt = Date.now();
      if (status === "done") snap.final = text;
      else snap.error = text;
      journal(status === "done" ? "done" : "error", { text: text.slice(0, 600) });
      runs.delete(id);
      finished.set(id, snap);
      while (finished.size > KEEP_FINISHED) finished.delete(finished.keys().next().value!);
    };

    log(`route ${id}: → ${project.name} (${decision.step}: ${decision.reason})`);
    snap.route = routeInfo(decision, session.cwd);
    journal("request", { text: firstLine });
    emit({
      type: "request.accepted",
      id,
      captureId: context.id,
      note: `Sent to ${project.name} · ${session.agent}`,
      route: snap.route,
    });
    const body = decision.mention ? stripMention(prompt, decision.mention) : prompt;
    try {
      for await (const e of session.send({ prompt: body, context, signal: abort.signal })) {
        if (!live()) continue;
        switch (e.type) {
          case "text":
            snap.text += e.text;
            emit({ type: "reply.delta", id, text: e.text });
            break;
          case "changed":
            journal("changed", { path: e.path });
            break;
          case "tool":
            snap.tools = [...snap.tools, e.summary].slice(-20);
            journal("tool", { summary: e.summary });
            emit({ type: "reply.tool", id, tool: e.tool, summary: e.summary });
            break;
          case "approval":
            snap.approvals.push({ approvalId: e.approvalId, tool: e.tool, summary: e.summary, detail: e.detail });
            journal("approval", { tool: e.tool, summary: e.summary });
            emit({ type: "approval.needed", id, approvalId: e.approvalId, tool: e.tool, summary: e.summary, detail: e.detail });
            break;
          case "approval.closed":
            snap.approvals = snap.approvals.filter((a) => a.approvalId !== e.approvalId);
            journal("tool", { summary: `No answer: ${e.reason}` });
            emit({ type: "approval.expired", id, approvalId: e.approvalId });
            break;
          case "done":
            emit({ type: "reply.done", id, text: e.text });
            finish("done", e.text);
            void sessions.updateSummary(project.id, text, e.text).then(() => broadcastProjects(), () => {});
            break;
          case "error":
            emit({ type: "reply.error", id, message: e.message });
            finish("failed", e.message);
            break;
        }
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      emit({ type: "reply.error", id, message });
      finish("failed", message);
    } finally {
      if (live()) {
        // The session ended without saying done or error.
        emit({ type: "reply.error", id, message: "The agent stopped without an answer." });
        finish("failed", "The agent stopped without an answer.");
      }
    }
  }

  async function startRequest(msg: Extract<ClientMessage, { type: "request" }>) {
    const c = msg.context;
    const coordinator = opts.coordinator!;
    // Stop works while the request is still being routed (the classifier can take seconds).
    const routing = new AbortController();
    starting.set(msg.id, routing);
    let decision: RouteDecision;
    try {
      decision = await coordinator.route({ id: msg.id, text: msg.text, context: c, project: msg.project });
    } catch (e) {
      log(`routing failed for ${msg.id}: ${e instanceof Error ? e.message : String(e)}`);
      decision = { project: coordinator.registry.inbox, step: "fallback", reason: "routing failed", ask: [] };
    } finally {
      starting.delete(msg.id);
    }
    if (routing.signal.aborted) {
      broadcast({ type: "reply.error", id: msg.id, message: "Cancelled." });
      return;
    }
    coordinator.noteRouted({ id: msg.id, text: msg.text, context: c }, decision);
    await run(msg.id, msg.prompt ?? msg.text, msg.text, c, decision);
  }

  async function reroute(ws: ServerWebSocket<Conn>, msg: Extract<ClientMessage, { type: "request.reroute" }>) {
    const coordinator = opts.coordinator!;
    // Every failure lands on the request's own bubble, so it never sits on "Moving…".
    // The request keeps running where it was, so this isn't the request's error.
    const fail = (message: string) => send(ws, { type: "reroute.failed", id: msg.id, message });
    const stored = store.byRequest(msg.id);
    if (!stored) return fail("That request is too old to move. Ask again.");
    const reg = coordinator.registry;
    let to = msg.project ? reg.get(msg.project) : undefined;
    let made = false;
    if (!to && msg.name) {
      to = reg.byName(msg.name);
      if (!to) {
        try {
          to = reg.save({ name: msg.name, description: `Started from: ${stored.text.slice(0, 120)}` });
        } catch (e) {
          return fail(e instanceof Error ? e.message : String(e));
        }
        made = true;
      }
    }
    if (!to) return fail("That project no longer exists.");
    // The low-confidence chooser answers one question; only a deliberate move teaches a rule.
    const rule = msg.learn === false ? undefined : coordinator.learnFromReroute(stored.context, to);
    const decision: RouteDecision = {
      project: to,
      step: "explicit",
      reason: `moved by you${made ? " to a new project" : ""}${rule ? `; ${rule.pattern} goes here from now on` : ""}`,
      ask: [],
    };
    coordinator.noteRouted({ id: msg.id, text: stored.text, context: stored.context }, decision);
    log(`reroute ${msg.id} → ${to.name}${rule ? ` (learned ${rule.kind} rule ${rule.pattern})` : ""}`);
    if (made || rule) broadcastProjects();
    await run(msg.id, stored.prompt ?? stored.text, stored.text, stored.context, decision);
  }

  function handleMessage(ws: ServerWebSocket<Conn>, raw: string | Buffer) {
    let msg: ClientMessage;
    try {
      msg = parseClientMessage(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
    } catch (e) {
      const detail = e instanceof ProtocolError ? e.message : String(e);
      // A refused request still gets an answer on its bubble, not just a log line.
      const id = requestIdOf(raw);
      if (id) send(ws, { type: "reply.error", id, message: `Superclick couldn't send this: ${detail}` });
      send(ws, { type: "error", error: "bad_message", detail });
      return;
    }
    const agents = !!(opts.sessions && opts.coordinator);
    const fail = (e: unknown) => {
      log(`error: ${e instanceof Error ? e.message : String(e)}`);
      send(ws, { type: "error", error: "failed", detail: e instanceof Error ? e.message : String(e) });
    };
    switch (msg.type) {
      case "hello":
        ws.data.client = `${msg.client} ${msg.version}`;
        log(`connected: ${ws.data.client}`);
        if (agents) {
          send(ws, { type: "agents", agents: agentStatus(false) });
          send(ws, { type: "projects", projects: projectInfo() });
          send(ws, { type: "sync", runs: snapshots() });
        }
        return;
      case "agents.check":
        send(ws, { type: "agents", agents: agentStatus(true) });
        return;
      case "ping":
        send(ws, { type: "pong" });
        return;
      case "request": {
        store.add({ id: msg.id, text: msg.text, prompt: msg.prompt, fullPage: msg.fullPage, context: msg.context });
        const c = msg.context;
        const words = c.page?.wordCount ?? 0;
        // Log the shape of the request, never its content.
        log(`request ${msg.id} from ${c.app.name}: ${msg.text.length} chars, page ${words} words, ` +
            `${Object.values(c.redactions).reduce((a, b) => a + b, 0)} redacted`);
        if (agents) {
          void startRequest(msg).catch(fail);
        } else {
          send(ws, { type: "request.accepted", id: msg.id, captureId: c.id, note: "Held locally; no agent is configured." });
        }
        return;
      }
      case "request.reroute":
        if (!agents) return fail(new Error("No agents are configured."));
        void reroute(ws, msg).catch(fail);
        return;
      case "approval.answer": {
        const ok = opts.sessions?.all().some((s) => s.approve(msg.approvalId, { allow: msg.allow, message: msg.message }));
        if (ok) {
          for (const r of runs.values()) r.snap.approvals = r.snap.approvals.filter((a) => a.approvalId !== msg.approvalId);
          // Every app window drops it, and its notification goes away.
          broadcast({ type: "approval.resolved", id: msg.id, approvalId: msg.approvalId, allow: msg.allow });
        } else {
          send(ws, { type: "approval.expired", id: msg.id, approvalId: msg.approvalId });
        }
        return;
      }
      case "request.cancel":
        starting.get(msg.id)?.abort();
        runs.get(msg.id)?.abort.abort();
        return;
      case "context.get":
        send(ws, { type: "context", captureId: msg.captureId, part: msg.part, text: store.part(msg.captureId, msg.part) });
        return;
      case "projects.list":
        send(ws, { type: "projects", projects: projectInfo() });
        return;
      case "capture.result": {
        const waiting = captures.get(msg.requestId);
        // Only the app that was asked can answer.
        if (!waiting || waiting.from !== ws) return;
        waiting.resolve({ markdown: msg.markdown ?? "", screenshot: msg.screenshot, refused: msg.refused });
        return;
      }
      case "catchup.get": {
        const reg = opts.coordinator?.registry;
        if (!reg || !opts.journal) return send(ws, { type: "catchup", since: msg.since, cards: [] });
        const live = new Map<string, "running" | "waiting">();
        for (const r of runs.values()) live.set(r.id, r.snap.approvals.length ? "waiting" : "running");
        const cards = opts.journal.catchUp(msg.since, (pid) => {
          const p = reg.get(pid);
          return p && { name: p.name, summary: opts.sessions?.summary(pid) ?? "" };
        }, live);
        for (const card of cards) {
          for (const q of card.requests) {
            const r = runs.get(q.id);
            if (r?.snap.approvals.length) q.waiting = r.snap.approvals;
          }
        }
        send(ws, { type: "catchup", since: msg.since, cards });
        return;
      }
      case "projects.save": {
        const reg = opts.coordinator?.registry;
        if (!reg) return fail(new Error("No agents are configured."));
        try {
          const before = msg.project.id ? reg.get(msg.project.id) : undefined;
          const saved = reg.save(msg.project);
          if (before && before.paths[0] !== saved.paths[0]) opts.sessions?.drop(saved.id);
        } catch (e) {
          return fail(e);
        }
        broadcastProjects();
        return;
      }
      case "projects.remove":
        if (!opts.coordinator?.registry.remove(msg.id)) return fail(new Error("Inbox can't be removed."));
        opts.sessions?.drop(msg.id);
        broadcastProjects();
        return;
      case "rules.save":
        try {
          opts.coordinator?.registry.addRule(msg.projectId, msg.kind, msg.pattern, "user");
        } catch (e) {
          return fail(e);
        }
        broadcastProjects();
        return;
      case "rules.remove":
        opts.coordinator?.registry.removeRule(msg.id);
        broadcastProjects();
        return;
    }
  }

  const server = Bun.serve<Conn, never>({
    hostname: "127.0.0.1",
    port: opts.port ?? DEFAULT_PORT,
    fetch(req, srv) {
      const url = new URL(req.url);
      if (url.pathname !== "/v1") return new Response("not found", { status: 404 });
      if (req.headers.get("origin")) return new Response("forbidden", { status: 403 });
      if (!tokenMatches(req.headers.get("authorization"), opts.token))
        return new Response("unauthorized", { status: 401 });
      if (srv.upgrade(req, { data: {} })) return undefined;
      return new Response("expected a WebSocket upgrade", { status: 426 });
    },
    websocket: {
      maxPayloadLength: 16 * 1024 * 1024,
      open(ws) {
        clients.add(ws);
        send(ws, { type: "welcome", version: VERSION, protocol: PROTOCOL_VERSION });
      },
      message(ws, raw) {
        // One bad message must never take the daemon down.
        try {
          handleMessage(ws, raw);
        } catch (e) {
          log(`error handling a message: ${e instanceof Error ? e.message : String(e)}`);
          send(ws, { type: "error", error: "internal", detail: "The daemon couldn't handle that message." });
        }
      },
      close(ws) {
        clients.delete(ws);
        for (const c of captures.values()) if (c.from === ws) c.resolve({ markdown: "", refused: "The Superclick app disconnected." });
        if (ws.data.client) log(`disconnected: ${ws.data.client}`);
      },
    },
  });

  return { server, store, stop: () => server.stop(true) };
}
