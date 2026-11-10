import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadOrCreateToken, tokenMatches } from "../src/auth.ts";
import { startDaemon } from "../src/server.ts";
import { bundle } from "./fixtures.ts";

const token = "t".repeat(64);
let daemon: ReturnType<typeof startDaemon>;
let url: string;

beforeAll(() => {
  daemon = startDaemon({ token, port: 0, log: () => {} });
  url = `ws://127.0.0.1:${daemon.server.port}/v1`;
});
afterAll(() => daemon.stop());

function open(headers: Record<string, string>): Promise<{ ws: WebSocket; next: () => Promise<any> }> {
  return new Promise((resolve, reject) => {
    // Bun's WebSocket client accepts headers, like the app's URLSessionWebSocketTask.
    const ws = new WebSocket(url, { headers } as any);
    const queue: any[] = [];
    const waiters: ((m: any) => void)[] = [];
    ws.onmessage = (e) => {
      const m = JSON.parse(String(e.data));
      const w = waiters.shift();
      w ? w(m) : queue.push(m);
    };
    const next = () => new Promise<any>((r) => (queue.length ? r(queue.shift()) : waiters.push(r)));
    ws.onopen = () => resolve({ ws, next });
    ws.onerror = () => reject(new Error("refused"));
  });
}

describe("daemon", () => {
  test("rejects connections without the token", async () => {
    const res = await fetch(url.replace("ws:", "http:"), { headers: { upgrade: "websocket" } });
    expect(res.status).toBe(401);
    await expect(open({ authorization: "Bearer wrong" })).rejects.toThrow();
  });

  test("rejects browser pages even with the token", async () => {
    const res = await fetch(url.replace("ws:", "http:"), {
      headers: { authorization: `Bearer ${token}`, origin: "https://evil.example" },
    });
    expect(res.status).toBe(403);
  });

  test("welcomes the app, accepts a request and serves its page", async () => {
    const { ws, next } = await open({ authorization: `Bearer ${token}` });
    expect((await next()).type).toBe("welcome");
    ws.send(JSON.stringify({ type: "hello", client: "test", version: "0" }));
    ws.send(JSON.stringify({ type: "request", id: "r1", text: "explain", fullPage: false, context: bundle() }));
    const accepted = await next();
    expect(accepted).toMatchObject({ type: "request.accepted", id: "r1", captureId: "cap-1" });

    ws.send(JSON.stringify({ type: "context.get", captureId: "cap-1", part: "full" }));
    expect(await next()).toMatchObject({ type: "context", text: "Intro. actors isolate state. End." });

    ws.send("garbage");
    expect(await next()).toMatchObject({ type: "error", error: "bad_message" });
    ws.close();
  });
});

describe("token", () => {
  test("is created once with owner-only permissions", () => {
    const dir = mkdtempSync(join(tmpdir(), "sc-"));
    const a = loadOrCreateToken(dir);
    const b = loadOrCreateToken(dir);
    expect(a).toBe(b);
    expect(a).toHaveLength(64);
    expect(statSync(join(dir, "daemon.token")).mode & 0o777).toBe(0o600);
  });

  test("matching is exact", () => {
    expect(tokenMatches(`Bearer ${token}`, token)).toBe(true);
    expect(tokenMatches(`Bearer ${token}x`, token)).toBe(false);
    expect(tokenMatches(token, token)).toBe(false);
    expect(tokenMatches(null, token)).toBe(false);
  });
});
