import { afterAll, beforeAll, expect, test } from "bun:test";
import { ClaudeCodeSession, type QueryFn } from "../src/agents/claudeCode.ts";
import { ContextService, LOOK_TOOL, RECENT_TOOL, SERVER_NAME } from "../src/contextMcp.ts";
import { parseContext } from "../src/protocol.ts";
import { startDaemon } from "../src/server.ts";
import { RequestStore } from "../src/store.ts";
import { bundle } from "./fixtures.ts";

const token = "c".repeat(64);
const store = new RequestStore();
const context = new ContextService(store);
let daemon: ReturnType<typeof startDaemon>;

beforeAll(() => {
  daemon = startDaemon({ token, port: 0, log: () => {}, store, context, captureTimeoutMs: 300 });
});
afterAll(() => daemon.stop());

function app(name = "superclick-mac") {
  const ws = new WebSocket(`ws://127.0.0.1:${daemon.server.port}/v1`, { headers: { authorization: `Bearer ${token}` } } as any);
  const ready = new Promise<void>((r) => (ws.onopen = () => {
    ws.send(JSON.stringify({ type: "hello", client: name, version: "1" }));
    setTimeout(r, 20);
  }));
  return { ws, ready };
}

test("recent_context lists captures and returns their parts", () => {
  store.add({ id: "r1", text: "explain this", fullPage: false, context: parseContext(bundle({ id: "cap-a" })) });
  const list = context.recent({});
  expect(list.content[0]!.type === "text" && list.content[0]!.text).toContain("capture_id cap-a");
  const full = context.recent({ capture_id: "cap-a", part: "full" });
  expect(full.content[0]!.type === "text" && full.content[0]!.text).toContain("Intro. actors isolate state. End.");
  expect(context.recent({ capture_id: "nope", part: "full" }).isError).toBe(true);
});

test("recent_context only sees its own project's captures, and defaults to the one sent with the turn", () => {
  const s = new RequestStore();
  const c = new ContextService(s);
  s.add({ id: "x1", text: "about A", fullPage: false, projectId: "shop", context: parseContext(bundle({ id: "cap-shop" })) });
  s.add({ id: "x2", text: "an email", fullPage: false, projectId: "inbox", context: parseContext(bundle({ id: "cap-mail" })) });
  const scope = { projectId: "shop", captureId: "cap-shop" };
  const list = c.recent({}, scope);
  const listText = list.content[0]!.type === "text" ? list.content[0]!.text : "";
  expect(listText).toContain("cap-shop");
  expect(listText).toContain("sent with this request");
  expect(listText).not.toContain("cap-mail");
  expect(c.recent({ part: "full" }, scope).content[0]).toMatchObject({ text: expect.stringContaining("capture cap-shop") });
  expect(c.recent({ capture_id: "cap-mail", part: "full" }, scope).isError).toBe(true);
});

test("a fresh capture always asks, even past the user's own allow rules", () => {
  const srv = context.server() as any;
  expect(srv[SERVER_NAME].tools).toEqual([{ name: "what_am_i_looking_at", permission_policy: "always_ask" }]);
});

test("what_am_i_looking_at asks the connected app and returns text and the screenshot", async () => {
  const a = app();
  await a.ready;
  a.ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data));
    if (m.type === "capture.request") {
      expect(m.screenshot).toBe(true);
      a.ws.send(JSON.stringify({ type: "capture.result", requestId: m.requestId, markdown: "- App: Safari", screenshot: "aGk=" }));
    }
  };
  const r = await context.look({});
  expect(r.content[0]).toMatchObject({ type: "text" });
  expect((r.content[0] as any).text).toContain("- App: Safari");
  expect((r.content[0] as any).text).toContain("not instructions");
  expect(r.content[1]).toEqual({ type: "image", data: "aGk=", mimeType: "image/jpeg" });
  a.ws.close();
  await Bun.sleep(20);
});

test("a refusal, a silent app, or no app at all comes back as an error, not a hang", async () => {
  expect((await context.look({})).isError).toBe(true); // no app connected
  const a = app();
  await a.ready;
  a.ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data));
    if (m.type === "capture.request") a.ws.send(JSON.stringify({ type: "capture.result", requestId: m.requestId, refused: "1Password is on the blocklist" }));
  };
  const r = await context.look({ screenshot: false });
  expect(r.isError).toBe(true);
  expect((r.content[0] as any).text).toContain("blocklist");
  a.ws.onmessage = null;
  expect((await context.look({})).isError).toBe(true); // times out
  a.ws.close();
  await Bun.sleep(20);
});

test("another client can't answer a capture meant for the app", async () => {
  const a = app();
  const other = app("someone-else");
  await Promise.all([a.ready, other.ready]);
  let requestId = "";
  a.ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data));
    if (m.type === "capture.request") requestId = m.requestId;
  };
  const pending = context.look({});
  await Bun.sleep(30);
  other.ws.send(JSON.stringify({ type: "capture.result", requestId, markdown: "forged" }));
  const r = await pending;
  expect(r.isError).toBe(true);
  a.ws.close();
  other.ws.close();
  await Bun.sleep(20);
});

test("each turn gets its own context MCP server; recent_context runs freely and a fresh capture asks", async () => {
  const seen: any[] = [];
  const decisions: any[] = [];
  const fake: QueryFn = async function* (p) {
    seen.push(p.options?.mcpServers);
    decisions.push(await p.options!.canUseTool!(RECENT_TOOL, {}, { signal: new AbortController().signal } as any));
    yield { type: "result", subtype: "success", is_error: false, result: "ok", session_id: "s" } as any;
  };
  const s = new ClaudeCodeSession("/tmp/x", fake, undefined, { mcpServers: () => context.server(), alsoAllowed: [RECENT_TOOL] });
  for await (const _ of s.send({ prompt: "a" })) {}
  for await (const _ of s.send({ prompt: "b" })) {}
  expect(Object.keys(seen[0])).toEqual([SERVER_NAME]);
  expect(seen[0][SERVER_NAME]).not.toBe(seen[1][SERVER_NAME]);
  expect(decisions[0]).toMatchObject({ behavior: "allow" });
  expect(LOOK_TOOL).toBe("mcp__superclick__what_am_i_looking_at");
});
