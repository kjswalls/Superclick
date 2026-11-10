import { afterAll, beforeAll, expect, test } from "bun:test";
import { ClaudeCodeAdapter, type QueryFn } from "../src/agents/claudeCode.ts";
import { startDaemon } from "../src/server.ts";
import { bundle, world } from "./fixtures.ts";

const token = "a".repeat(64);
let daemon: ReturnType<typeof startDaemon>;
let prompts: string[] = [];

// A stand-in for Claude Code: streams two pieces, asks to run a command, then answers.
const fake: QueryFn = async function* (p) {
  prompts.push(p.prompt);
  if (p.prompt.startsWith("slow")) {
    // Waits until aborted, like a long turn that gets rerouted.
    await new Promise<void>((r) => p.options!.abortController!.signal.addEventListener("abort", () => r()));
    throw new Error("aborted");
  }
  if (p.prompt.startsWith("quick")) {
    yield { type: "result", subtype: "success", is_error: false, result: `done in ${p.options!.cwd}`, session_id: "q" } as any;
    return;
  }
  const ev = (text: string) => ({ type: "stream_event", parent_tool_use_id: null, session_id: "s", uuid: "u",
    event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } }) as any;
  yield ev("Checking");
  const d = await p.options!.canUseTool!("Bash", { command: "bin/rails test" }, { signal: new AbortController().signal } as any);
  yield ev(d?.behavior === "allow" ? " ran it." : " skipped.");
  yield { type: "result", subtype: "success", is_error: false, result: "All green.", session_id: "s" } as any;
};

let w: ReturnType<typeof world>;
beforeAll(() => {
  w = world(new ClaudeCodeAdapter(fake));
  daemon = startDaemon({ token, port: 0, log: () => {}, sessions: w.sessions, coordinator: w.coordinator, journal: w.journal });
});

function connect() {
  const ws = new WebSocket(`ws://127.0.0.1:${daemon.server.port}/v1`, { headers: { authorization: `Bearer ${token}` } } as any);
  const got: any[] = [];
  const waiters: [(m: any) => boolean, (m: any) => void][] = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data));
    got.push(m);
    for (const [i, [pred, res]] of waiters.entries()) if (pred(m)) { waiters.splice(i, 1); res(m); break; }
  };
  const until = (pred: (m: any) => boolean) => new Promise<any>((res) => {
    const hit = got.find(pred);
    hit ? res(hit) : waiters.push([pred, res]);
  });
  return { ws, got, until, ready: new Promise((r) => (ws.onopen = r)) };
}
afterAll(() => daemon.stop());

test("a request streams a reply, asks for approval, and finishes", async () => {
  const ws = new WebSocket(`ws://127.0.0.1:${daemon.server.port}/v1`, { headers: { authorization: `Bearer ${token}` } } as any);
  const got: any[] = [];
  const done = new Promise<void>((resolve) => {
    ws.onmessage = (e) => {
      const m = JSON.parse(String(e.data));
      got.push(m);
      if (m.type === "approval.needed") ws.send(JSON.stringify({ type: "approval.answer", approvalId: m.approvalId, allow: true }));
      if (m.type === "reply.done" || m.type === "reply.error") resolve();
    };
  });
  await new Promise((r) => (ws.onopen = r));
  ws.send(JSON.stringify({ type: "request", id: "r1", text: "run tests", prompt: "run tests\n\n---\nContext…", context: bundle() }));
  await done;
  ws.close();

  const types = got.map((m) => m.type);
  expect(types).toEqual(["welcome", "request.accepted", "reply.delta", "approval.needed", "approval.resolved", "reply.delta", "reply.done"]);
  expect(got[1].route).toMatchObject({ project: "Inbox", agent: "Claude Code", step: "fallback", projectId: "inbox" });
  expect(got[3].summary).toBe("Bash bin/rails test");
  expect(got[5].text).toBe(" ran it.");
  expect(got[6].text).toBe("All green.");
  expect(prompts[0]).toBe("run tests\n\n---\nContext…");
});

test("a reroute moves a running request, learns a rule, and silences the old run", async () => {
  const c = connect();
  await c.ready;
  c.ws.send(JSON.stringify({ type: "hello", client: "test", version: "1" }));
  await c.until((m) => m.type === "projects");
  c.ws.send(JSON.stringify({ type: "request", id: "r2", text: "slow please", prompt: "slow please",
    context: bundle({ id: "cap-2", url: "https://github.com/me/shop/issues/1" }) }));
  const first = await c.until((m) => m.type === "request.accepted" && m.id === "r2");
  expect(first.route.project).toBe("Inbox");
  c.ws.send(JSON.stringify({ type: "request.reroute", id: "r2", name: "shop" }));
  const moved = await c.until((m) => m.type === "request.accepted" && m.id === "r2" && m.route.project === "shop");
  expect(moved.route.reason).toContain("github.com/me/shop/*");
  const projects = await c.until((m) => m.type === "projects" && m.projects.some((p: any) => p.name === "shop"));
  expect(projects.projects.find((p: any) => p.name === "shop").rules[0].pattern).toBe("github.com/me/shop/*");
  // The rerouted run waits like the original (slow); cancel it and check the old Inbox run said nothing.
  c.ws.send(JSON.stringify({ type: "request.cancel", id: "r2" }));
  await c.until((m) => m.type === "reply.error" && m.id === "r2");
  await Bun.sleep(20);
  expect(c.got.filter((m) => m.type === "reply.error" && m.id === "r2")).toHaveLength(1);

  // Next time the same repo page routes to shop by rule.
  c.ws.send(JSON.stringify({ type: "request", id: "r3", text: "quick one", prompt: "quick one",
    context: bundle({ id: "cap-3", url: "https://github.com/me/shop/pull/2" }) }));
  const next = await c.until((m) => m.type === "request.accepted" && m.id === "r3");
  expect(next.route).toMatchObject({ project: "shop", step: "rule" });
  await c.until((m) => m.type === "reply.done" && m.id === "r3");
  c.ws.close();
});

test("projects can be added, renamed and removed over the socket", async () => {
  const c = connect();
  await c.ready;
  c.ws.send(JSON.stringify({ type: "projects.save", project: { name: "notes", description: "my notes" } }));
  const a = await c.until((m) => m.type === "projects" && m.projects.some((p: any) => p.name === "notes"));
  const notes = a.projects.find((p: any) => p.name === "notes");
  c.ws.send(JSON.stringify({ type: "projects.save", project: { id: notes.id, name: "journal" } }));
  await c.until((m) => m.type === "projects" && m.projects.some((p: any) => p.name === "journal"));
  c.ws.send(JSON.stringify({ type: "projects.save", project: { name: "x", paths: ["relative/path"] } }));
  expect(await c.until((m) => m.type === "error")).toMatchObject({ error: "bad_message" });
  c.ws.send(JSON.stringify({ type: "projects.remove", id: notes.id }));
  await c.until((m) => m.type === "projects" && !m.projects.some((p: any) => p.id === notes.id));
  c.ws.close();
});


test("a reconnecting app gets running and recently finished requests back", async () => {
  const a = connect();
  await a.ready;
  a.ws.send(JSON.stringify({ type: "request", id: "r5", text: "slow again", prompt: "slow again", context: bundle({ id: "cap-5" }) }));
  await a.until((m) => m.type === "request.accepted" && m.id === "r5");
  a.ws.close();

  const b = connect();
  await b.ready;
  b.ws.send(JSON.stringify({ type: "hello", client: "test", version: "2" }));
  const sync = await b.until((m) => m.type === "sync");
  const r5 = sync.runs.find((r: any) => r.id === "r5");
  expect(r5).toMatchObject({ status: "running", route: { project: "Inbox" } });
  const r3 = sync.runs.find((r: any) => r.id === "r3");
  expect(r3).toMatchObject({ status: "done" });
  b.ws.send(JSON.stringify({ type: "request.cancel", id: "r5" }));
  await b.until((m) => m.type === "reply.error" && m.id === "r5");
  b.ws.close();
});

test("a refused request gets an error on its own id; an expired approval says so", async () => {
  const c = connect();
  await c.ready;
  c.ws.send(JSON.stringify({ type: "request", id: "bad1", text: "x", context: { id: "c" } }));
  expect(await c.until((m) => m.type === "reply.error")).toMatchObject({ id: "bad1" });
  c.ws.send(JSON.stringify({ type: "approval.answer", id: "r9", approvalId: "nope", allow: true }));
  expect(await c.until((m) => m.type === "approval.expired")).toMatchObject({ id: "r9", approvalId: "nope" });
  c.ws.close();
});

test("catch-up cards come back over the socket", async () => {
  const c = connect();
  await c.ready;
  c.ws.send(JSON.stringify({ type: "catchup.get", since: 0 }));
  const m = await c.until((x) => x.type === "catchup");
  const shop = m.cards.find((x: any) => x.project === "shop");
  expect(shop.requests.find((r: any) => r.id === "r3")).toMatchObject({ status: "done", text: "quick one" });
  c.ws.close();
});

test("a failed reroute reaches the request's own bubble without failing it", async () => {
  const c = connect();
  await c.ready;
  c.ws.send(JSON.stringify({ type: "request.reroute", id: "never-sent", name: "shop" }));
  expect(await c.until((m) => m.type === "reroute.failed" && m.id === "never-sent")).toMatchObject({ message: expect.stringContaining("too old") });
  c.ws.send(JSON.stringify({ type: "request.reroute", id: "r3", name: "a name that is far too long to be a project" }));
  expect(await c.until((m) => m.type === "reroute.failed" && m.id === "r3")).toMatchObject({ message: "Keep project names short." });
  c.ws.close();
});

test("the chooser moves a request without learning a rule", async () => {
  const c = connect();
  await c.ready;
  c.ws.send(JSON.stringify({ type: "request", id: "r7", text: "quick seven", prompt: "quick seven",
    context: bundle({ id: "cap-7", url: "https://blog.example.com/posts/7" }) }));
  await c.until((m) => m.type === "reply.done" && m.id === "r7");
  c.ws.send(JSON.stringify({ type: "request.reroute", id: "r7", name: "shop", learn: false }));
  await c.until((m) => m.type === "request.accepted" && m.id === "r7" && m.route.project === "shop");
  expect(w.registry.rules().some((r) => r.pattern.startsWith("blog.example.com"))).toBe(false);
  await c.until((m) => m.type === "reply.done" && m.id === "r7" && m.text.includes("shop"));
  c.ws.close();
});

test("removing a project stops its running turn", async () => {
  const c = connect();
  await c.ready;
  const p = w.registry.save({ name: "doomed" });
  c.ws.send(JSON.stringify({ type: "request", id: "r8", text: "slow doomed", prompt: "slow doomed", project: p.id,
    context: bundle({ id: "cap-8" }) }));
  await c.until((m) => m.type === "request.accepted" && m.id === "r8");
  c.ws.send(JSON.stringify({ type: "projects.remove", id: p.id }));
  expect(await c.until((m) => m.type === "reply.error" && m.id === "r8")).toMatchObject({ message: "Cancelled." });
  c.ws.close();
});

