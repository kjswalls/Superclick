import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ClaudeCodeAdapter, type QueryFn } from "../src/agents/claudeCode.ts";
import { startDaemon } from "../src/server.ts";
import { SessionManager } from "../src/sessions.ts";
import { bundle } from "./fixtures.ts";

const token = "a".repeat(64);
let daemon: ReturnType<typeof startDaemon>;
let prompts: string[] = [];

// A stand-in for Claude Code: streams two pieces, asks to run a command, then answers.
const fake: QueryFn = async function* (p) {
  prompts.push(p.prompt);
  const ev = (text: string) => ({ type: "stream_event", parent_tool_use_id: null, session_id: "s", uuid: "u",
    event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } }) as any;
  yield ev("Checking");
  const d = await p.options!.canUseTool!("Bash", { command: "bin/rails test" }, { signal: new AbortController().signal } as any);
  yield ev(d?.behavior === "allow" ? " ran it." : " skipped.");
  yield { type: "result", subtype: "success", is_error: false, result: "All green.", session_id: "s" } as any;
};

beforeAll(() => {
  const home = mkdtempSync(join(tmpdir(), "home-"));
  daemon = startDaemon({ token, port: 0, log: () => {}, sessions: new SessionManager(new ClaudeCodeAdapter(fake), home) });
});
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
  expect(types).toEqual(["welcome", "request.accepted", "reply.delta", "approval.needed", "reply.delta", "reply.done"]);
  expect(got[1].route).toMatchObject({ project: "Inbox", agent: "Claude Code" });
  expect(got[3].summary).toBe("Bash bin/rails test");
  expect(got[4].text).toBe(" ran it.");
  expect(got[5].text).toBe("All green.");
  expect(prompts[0]).toBe("run tests\n\n---\nContext…");
});
