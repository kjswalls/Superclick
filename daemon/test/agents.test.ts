import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentEvent } from "../src/agents/adapter.ts";
import { ClaudeCodeSession, describeTool, type QueryFn } from "../src/agents/claudeCode.ts";
import { parseContext } from "../src/protocol.ts";
import { SessionManager, routeFor } from "../src/sessions.ts";
import { bundle } from "./fixtures.ts";

const delta = (text: string) => ({
  type: "stream_event", parent_tool_use_id: null, session_id: "s1", uuid: "u",
  event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
});
const blockStart = () => ({
  type: "stream_event", parent_tool_use_id: null, session_id: "s1", uuid: "u",
  event: { type: "content_block_start", index: 1, content_block: { type: "text", text: "" } },
});
const result = (text: string) => ({ type: "result", subtype: "success", is_error: false, result: text, session_id: "s1" });

async function collect(it: AsyncIterable<AgentEvent>) {
  const out: AgentEvent[] = [];
  for await (const e of it) out.push(e);
  return out;
}

describe("ClaudeCodeSession", () => {
  test("streams text, separates blocks and finishes with the final answer", async () => {
    const seen: any[] = [];
    const fake: QueryFn = async function* (p) {
      seen.push(p.options);
      yield delta("Hel") as any;
      yield delta("lo") as any;
      yield blockStart() as any;
      yield delta("World") as any;
      yield result("World") as any;
    };
    const s = new ClaudeCodeSession("/tmp/x", fake);
    const events = await collect(s.send({ prompt: "hi" }));
    expect(events.filter((e) => e.type === "text").map((e: any) => e.text).join("")).toBe("Hello\n\nWorld");
    expect(events.at(-1)).toEqual({ type: "done", text: "World" });
    expect(seen[0].cwd).toBe("/tmp/x");
    expect(seen[0].resume).toBeUndefined();

    // The next turn resumes the same Claude Code session.
    await collect(s.send({ prompt: "again" }));
    expect(seen[1].resume).toBe("s1");
  });

  test("asks before tools that change things and passes typed answers back", async () => {
    let decision: any;
    const fake: QueryFn = async function* (p) {
      const read = await p.options!.canUseTool!("Read", { file_path: "/a" }, { signal: new AbortController().signal } as any);
      expect(read?.behavior).toBe("allow");
      decision = await p.options!.canUseTool!("Bash", { command: "rm -rf build" }, { signal: new AbortController().signal } as any);
      yield result("ok") as any;
    };
    const s = new ClaudeCodeSession("/tmp/x", fake);
    const events: AgentEvent[] = [];
    for await (const e of s.send({ prompt: "clean" })) {
      events.push(e);
      if (e.type === "approval") {
        expect(e.summary).toBe("Bash rm -rf build");
        s.approve(e.approvalId, { allow: false, message: "only delete build/tmp" });
      }
    }
    expect(decision).toEqual({ behavior: "deny", message: "The user said: only delete build/tmp" });
    expect(events.at(-1)?.type).toBe("done");
  });

  test("times out unanswered approvals as a denial", async () => {
    let decision: any;
    const fake: QueryFn = async function* (p) {
      decision = await p.options!.canUseTool!("Write", { file_path: "/a" }, { signal: new AbortController().signal } as any);
      yield result("ok") as any;
    };
    const s = new ClaudeCodeSession("/tmp/x", fake, 20);
    await collect(s.send({ prompt: "write" }));
    expect(decision.behavior).toBe("deny");
  });

  test("reports errors, including sign-in problems", async () => {
    const fake: QueryFn = async function* () {
      throw new Error("Invalid API key · Please run /login");
    };
    const events = await collect(new ClaudeCodeSession("/tmp/x", fake).send({ prompt: "x" }));
    expect(events).toHaveLength(1);
    expect(events[0]!.type).toBe("error");
    expect((events[0] as any).message).toContain("isn't signed in");
  });

  test("describes tool calls on one short line", () => {
    expect(describeTool("Grep", { pattern: "TODO" })).toBe("Grep TODO");
    expect(describeTool("Bash", { command: "a\n  b" })).toBe("Bash a b");
    expect(describeTool("X", {})).toBe("X");
  });
});

describe("routing", () => {
  const home = mkdtempSync(join(tmpdir(), "home-"));
  const repo = join(home, "code", "shop");
  mkdirSync(join(repo, ".git"), { recursive: true });
  mkdirSync(join(repo, "app", "models"), { recursive: true });
  writeFileSync(join(repo, "app", "models", "order.rb"), "");

  test("a file inside a git repo routes to the repo", () => {
    const r = routeFor(parseContext(bundle({ filePath: join(repo, "app", "models", "order.rb") })), home);
    expect(r.cwd).toBe(repo);
    expect(r.project).toBe("shop");
  });

  test("a terminal folder routes to its repo", () => {
    expect(routeFor(parseContext(bundle({ cwd: join(repo, "app") })), home).project).toBe("shop");
  });

  test("no folder goes to the Inbox", () => {
    expect(routeFor(parseContext(bundle()), home)).toMatchObject({ cwd: home, project: "Inbox" });
    expect(routeFor(parseContext(bundle({ filePath: "/does/not/exist.txt" })), home).project).toBe("Inbox");
  });

  test("one session per folder", () => {
    let started = 0;
    const m = new SessionManager({ name: "fake", startSession: ({ cwd }) => { started++; return new ClaudeCodeSession(cwd); } }, home);
    const a = m.route(parseContext(bundle({ cwd: repo }))).session;
    const b = m.route(parseContext(bundle({ filePath: join(repo, "app", "models", "order.rb") }))).session;
    m.route(parseContext(bundle()));
    expect(a).toBe(b);
    expect(started).toBe(2);
  });
});
