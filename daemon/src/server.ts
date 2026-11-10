import type { Server, ServerWebSocket } from "bun";
import { tokenMatches } from "./auth.ts";
import { PROTOCOL_VERSION, ProtocolError, parseClientMessage, type ServerMessage } from "./protocol.ts";
import { RequestStore } from "./store.ts";

export const DEFAULT_PORT = 47811;
export const VERSION = "0.1.0";

export interface DaemonOptions {
  token: string;
  port?: number;
  store?: RequestStore;
  log?: (line: string) => void;
}

interface Conn {
  client?: string;
}

/**
 * The daemon's local WebSocket API. It listens on 127.0.0.1 only, and accepts
 * a connection only when it presents the token from daemon.token and carries
 * no Origin header, so web pages in a browser can't reach it.
 */
export function startDaemon(opts: DaemonOptions): { server: Server<Conn>; store: RequestStore; stop: () => void } {
  const store = opts.store ?? new RequestStore();
  const log = opts.log ?? ((l: string) => console.log(`[superclick] ${l}`));

  const send = (ws: ServerWebSocket<Conn>, m: ServerMessage) => ws.send(JSON.stringify(m));

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
        send(ws, { type: "welcome", version: VERSION, protocol: PROTOCOL_VERSION });
      },
      message(ws, raw) {
        let msg;
        try {
          msg = parseClientMessage(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
        } catch (e) {
          const detail = e instanceof ProtocolError ? e.message : String(e);
          send(ws, { type: "error", error: "bad_message", detail });
          return;
        }
        switch (msg.type) {
          case "hello":
            ws.data.client = `${msg.client} ${msg.version}`;
            log(`connected: ${ws.data.client}`);
            return;
          case "ping":
            send(ws, { type: "pong" });
            return;
          case "request": {
            store.add({ id: msg.id, text: msg.text, fullPage: msg.fullPage, context: msg.context });
            const c = msg.context;
            const words = c.page?.wordCount ?? 0;
            // Log the shape of the request, never its content.
            log(`request ${msg.id} from ${c.app.name}: ${msg.text.length} chars, page ${words} words, ` +
                `${Object.values(c.redactions).reduce((a, b) => a + b, 0)} redacted`);
            send(ws, {
              type: "request.accepted",
              id: msg.id,
              captureId: c.id,
              note: "Held locally. Agent sessions arrive in M2.",
            });
            return;
          }
          case "context.get":
            send(ws, { type: "context", captureId: msg.captureId, part: msg.part, text: store.part(msg.captureId, msg.part) });
            return;
        }
      },
      close(ws) {
        if (ws.data.client) log(`disconnected: ${ws.data.client}`);
      },
    },
  });

  return { server, store, stop: () => server.stop(true) };
}
